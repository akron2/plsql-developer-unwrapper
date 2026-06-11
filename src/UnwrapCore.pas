unit UnwrapCore;

{
  Native Free Pascal port of app/unwrap.py (decode_body).

  Pipeline (reverse of Oracle's 10g+ wrap), byte-for-byte identical to the
  canonical Python core:

    base64 body
      -> base64 decode                         (raw buffer)
      -> byte-wise de-substitution via CHARMAP  (whole buffer)
      -> split: [0..19] = SHA-1 over the stream, [20..] = zlib stream
      -> optional SHA-1 integrity check
      -> zlib inflate
      -> strip the single trailing NUL byte that wrap appends
      -> decode bytes to text (infer source charset: utf-8, else the most
         Russian-looking single-byte Cyrillic code page) -> host ANSI

  Wrap is obfuscation, not encryption. No database, no network.
  CHARMAP is generated from app/unwrap.py by plugin/tools/gen_charmap.py;
  never edit Charmap.inc by hand.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TUnwrapErrorKind = (uekNotWrapped, uekLegacy, uekIntegrity, uekMalformed);

  EUnwrapError = class(Exception)
  private
    FKind: TUnwrapErrorKind;
  public
    constructor CreateKind(AKind: TUnwrapErrorKind; const Msg: string);
    property Kind: TUnwrapErrorKind read FKind;
  end;

{ Decode a single base64 wrap body into source text.
  Sha1Ok reports whether the embedded SHA-1 matched the stream, regardless of
  Verify. When Verify is True a mismatch raises EUnwrapError(uekIntegrity).
  Lossy reports whether any source character had no representation in the host
  ANSI code page and was replaced with '?' — an inherent limit of the ANSI
  (char*) plug-in API, surfaced so the caller can warn the user. }
function DecodeBody(const B64Body: AnsiString; Verify: Boolean;
  out Sha1Ok: Boolean; out Lossy: Boolean): AnsiString; overload;
function DecodeBody(const B64Body: AnsiString; Verify: Boolean;
  out Sha1Ok: Boolean): AnsiString; overload;

{ The Windows code page inferred for raw (decompressed) source bytes: CP_UTF8
  (65001) when valid UTF-8, one of the Cyrillic code pages when the bytes look
  like Russian, or 0 when undetermined. Exposed for tests. }
function InferSourceCodePage(const Data: AnsiString): Cardinal;

implementation

uses
  Classes, base64, sha1, zstream, Windows;

{$I Charmap.inc}

constructor EUnwrapError.CreateKind(AKind: TUnwrapErrorKind; const Msg: string);
begin
  inherited Create(Msg);
  FKind := AKind;
end;

{ Remove all ASCII whitespace from a base64 blob. }
function StripWhitespace(const S: AnsiString): AnsiString;
var
  I, J: Integer;
  C: AnsiChar;
begin
  SetLength(Result, Length(S));
  J := 0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C <> ' ') and (C <> #9) and (C <> #10) and (C <> #13) then
    begin
      Inc(J);
      Result[J] := C;
    end;
  end;
  SetLength(Result, J);
end;

{ Validate a UTF-8 byte sequence without decoding it. }
function IsValidUtf8(const S: AnsiString): Boolean;
var
  I, N, Extra: Integer;
  B: Byte;
begin
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    B := Ord(S[I]);
    if B < $80 then
      Extra := 0
    else if (B and $E0) = $C0 then
      Extra := 1
    else if (B and $F0) = $E0 then
      Extra := 2
    else if (B and $F8) = $F0 then
      Extra := 3
    else
      Exit(False);
    if I + Extra > N then
      Exit(False);
    while Extra > 0 do
    begin
      Inc(I);
      if (Ord(S[I]) and $C0) <> $80 then
        Exit(False);
      Dec(Extra);
    end;
    Inc(I);
  end;
  Result := True;
end;

const
  CP_CP1251    = 1251;
  CP_ISO8859_5 = 28595;
  CP_KOI8R     = 20866;
  CP_CP866     = 866;

  // Relative frequencies of Russian letters а..я (index = code point - $0430),
  // mirrored verbatim from app/unwrap.py _RU_FREQ. Drives the source-charset
  // guess: real Russian scores high, code-page gibberish scores low.
  RU_WEIGHT: array[0..31] of Integer = (
     80,  16,  45,  17,  30,  85,   9,  16,  74,  12,  35,  44,  32,  67, 110,  28,
     47,  55,  63,  26,   2,  10,   5,  14,   7,   4,   1,  19,  17,   3,   6,  20
  );

  // Candidate single-byte Cyrillic code pages, in the same order as the core.
  CYR_CODEPAGES: array[0..3] of Cardinal =
    (CP_CP1251, CP_ISO8859_5, CP_KOI8R, CP_CP866);

{ Heuristic: higher when the text reads like real Russian, not gibberish.
  Mirrors app/unwrap.py _russian_score. }
function RussianScore(const W: UnicodeString): Integer;
var
  I, Code, Low: Integer;
begin
  Result := 0;
  for I := 1 to Length(W) do
  begin
    Code := Ord(W[I]);
    if (Code >= $0410) and (Code <= $042F) then
      Low := Code + $20          // А..Я -> а..я
    else if Code = $0401 then
      Low := $0451               // Ё -> ё
    else
      Low := Code;
    if (Low >= $0430) and (Low <= $044F) then
      Inc(Result, RU_WEIGHT[Low - $0430])
    else if Low = $0451 then
      Inc(Result, 1)             // ё
    else if (Code >= $0400) and (Code <= $04FF) then
      Dec(Result, 5)             // Cyrillic block, but not a common Russian letter
    else if Code < $80 then
      Continue                   // ASCII: shared by all code pages, no signal
    else
      Dec(Result, 30);           // symbols/controls -> almost certainly wrong page
  end;
end;

{ Decode Data from a given code page to UTF-16 (never fails for single-byte
  pages; returns '' only on an empty input or an API error). }
function WidenFrom(const Data: AnsiString; CodePage: Cardinal): UnicodeString;
var
  WideLen: Integer;
begin
  Result := '';
  if Length(Data) = 0 then
    Exit;
  WideLen := MultiByteToWideChar(CodePage, 0, PAnsiChar(Data), Length(Data), nil, 0);
  if WideLen <= 0 then
    Exit;
  SetLength(Result, WideLen);
  MultiByteToWideChar(CodePage, 0, PAnsiChar(Data), Length(Data),
    PWideChar(Result), WideLen);
end;

function InferSourceCodePage(const Data: AnsiString): Cardinal;
var
  I, Score, BestScore: Integer;
begin
  if Length(Data) = 0 then
    Exit(CP_UTF8);                 // empty / ASCII: UTF-8 is the safe identity
  if IsValidUtf8(Data) then
    Exit(CP_UTF8);                 // AL32UTF8 source

  Result := 0;                     // 0 = undetermined -> caller passes bytes through
  BestScore := 0;                  // a candidate must look positively Russian to win
  for I := Low(CYR_CODEPAGES) to High(CYR_CODEPAGES) do
  begin
    Score := RussianScore(WidenFrom(Data, CYR_CODEPAGES[I]));
    if Score > BestScore then
    begin
      BestScore := Score;
      Result := CYR_CODEPAGES[I];
    end;
  end;
end;

{ Decode source bytes to text by inferring the database character set, and
  report whether the final conversion to the host code page lost any character.

  Mirrors app/unwrap.py: UTF-8 first, otherwise the most Russian-looking
  single-byte Cyrillic code page; when nothing looks Russian, the 8-bit bytes
  are passed through unchanged (the lossless last resort). The recovered Unicode
  is then encoded to the host ANSI code page (CP_ACP, cp1251 on a Russian
  Windows) for the char*-based plug-in API, via the Win32 API so the result is
  deterministic and independent of the FPC widestring manager.

  Lossy is set when a character had no representation in the host code page and
  was replaced with '?'. That cannot be avoided here (the plug-in API hands the
  IDE a char*), but it is reported instead of corrupting data silently. }
function DecodeText(const Data: AnsiString; out Lossy: Boolean): AnsiString;
var
  Wide: UnicodeString;
  CodePage: Cardinal;
  AnsiLen: Integer;
  UsedDefault: LongBool;
begin
  Lossy := False;
  if Length(Data) = 0 then
    Exit('');

  CodePage := InferSourceCodePage(Data);
  if CodePage = 0 then
  begin
    // Not UTF-8 and nothing looked Russian: leave the 8-bit bytes as-is.
    Result := Data;
    Exit;
  end;

  Wide := WidenFrom(Data, CodePage);
  if Length(Wide) = 0 then
  begin
    Result := Data;
    Exit;
  end;

  // Unicode -> host ANSI code page (CP_ACP), flagging any lossy replacement.
  AnsiLen := WideCharToMultiByte(CP_ACP, 0, PWideChar(Wide), Length(Wide),
    nil, 0, nil, nil);
  if AnsiLen <= 0 then
  begin
    Result := Data;
    Exit;
  end;
  SetLength(Result, AnsiLen);
  UsedDefault := False;
  WideCharToMultiByte(CP_ACP, 0, PWideChar(Wide), Length(Wide),
    PAnsiChar(Result), AnsiLen, nil, @UsedDefault);
  Lossy := UsedDefault;
end;

{ Inflate a zlib stream (with header), unknown output size. }
function Inflate(const Stream: AnsiString): AnsiString;
var
  Src, Outp: TMemoryStream;
  Dec: TDecompressionStream;
  Buf: array[0..16383] of Byte;
  N: LongInt;
begin
  Result := '';
  Src := TMemoryStream.Create;
  try
    Src.WriteBuffer(Stream[1], Length(Stream));
    Src.Position := 0;
    Dec := TDecompressionStream.Create(Src);  // zlib format (with header)
    try
      Outp := TMemoryStream.Create;
      try
        repeat
          N := Dec.Read(Buf, SizeOf(Buf));
          if N > 0 then
            Outp.WriteBuffer(Buf, N);
        until N <= 0;
        SetLength(Result, Outp.Size);
        if Outp.Size > 0 then
          Move(Outp.Memory^, Result[1], Outp.Size);
      finally
        Outp.Free;
      end;
    finally
      Dec.Free;
    end;
  finally
    Src.Free;
  end;
end;

function DecodeBody(const B64Body: AnsiString; Verify: Boolean;
  out Sha1Ok: Boolean; out Lossy: Boolean): AnsiString;
var
  Compact, Raw, Buffer, Stored, Stream, Data: AnsiString;
  I, N: Integer;
  Digest: TSHA1Digest;
begin
  Sha1Ok := False;
  Lossy := False;

  Compact := StripWhitespace(B64Body);
  Raw := DecodeStringBase64(Compact);
  if Length(Raw) <= 20 then
    raise EUnwrapError.CreateKind(uekMalformed,
      'body too short to contain a hash and a stream');

  N := Length(Raw);
  SetLength(Buffer, N);
  for I := 1 to N do
    Buffer[I] := AnsiChar(CHARMAP[Ord(Raw[I])]);

  Stored := Copy(Buffer, 1, 20);
  Stream := Copy(Buffer, 21, N - 20);

  Digest := SHA1Buffer(Stream[1], Length(Stream));
  Sha1Ok := True;
  for I := 0 to 19 do
    if Digest[I] <> Byte(Stored[I + 1]) then
    begin
      Sha1Ok := False;
      Break;
    end;

  if Verify and (not Sha1Ok) then
    raise EUnwrapError.CreateKind(uekIntegrity,
      'SHA-1 hash does not match — the wrapped code was modified or is corrupt');

  try
    Data := Inflate(Stream);
  except
    on E: Exception do
      raise EUnwrapError.CreateKind(uekMalformed,
        'zlib stream could not be decompressed: ' + E.Message);
  end;

  if (Length(Data) > 0) and (Data[Length(Data)] = #0) then
    SetLength(Data, Length(Data) - 1);

  Result := DecodeText(Data, Lossy);
end;

function DecodeBody(const B64Body: AnsiString; Verify: Boolean;
  out Sha1Ok: Boolean): AnsiString;
var
  IgnoredLossy: Boolean;
begin
  Result := DecodeBody(B64Body, Verify, Sha1Ok, IgnoredLossy);
end;

end.
