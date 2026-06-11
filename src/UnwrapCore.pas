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
      -> decode bytes to text (utf-8 -> system ANSI; else pass-through)

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
  Verify. When Verify is True a mismatch raises EUnwrapError(uekIntegrity). }
function DecodeBody(const B64Body: AnsiString; Verify: Boolean;
  out Sha1Ok: Boolean): AnsiString;

implementation

uses
  Classes, base64, sha1, zstream;

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

{ Decode source bytes, tolerating non-UTF-8 database character sets.
  Mirrors Python's utf-8 -> cp1251 -> latin-1 chain for an ANSI host:
  valid UTF-8 is converted to the system ANSI code page (cp1251 on a Russian
  Windows); otherwise the bytes are already in an 8-bit code page and pass
  through unchanged (latin-1 is the lossless last resort). }
function DecodeText(const Data: AnsiString): AnsiString;
begin
  if IsValidUtf8(Data) then
    Result := Utf8ToAnsi(Data)   // ASCII stays ASCII; multibyte -> ANSI
  else
    Result := Data;
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
  out Sha1Ok: Boolean): AnsiString;
var
  Compact, Raw, Buffer, Stored, Stream, Data: AnsiString;
  I, N: Integer;
  Digest: TSHA1Digest;
begin
  Sha1Ok := False;

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

  Result := DecodeText(Data);
end;

end.
