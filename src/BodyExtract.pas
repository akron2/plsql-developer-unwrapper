unit BodyExtract;

{
  Port of the relevant part of app/parser.py (_extract_base64), extended to
  batch and to preserving non-wrapped text.

  Given the text of an editor window, locate every wrapped object's base64 body
  AND its line span, so the caller can replace each wrapped block in place with
  its unwrapped source while leaving non-wrapped statements untouched — e.g. a
  plain package spec sitting next to a wrapped body, or vice versa. Nothing is
  dropped.

  Shapes handled: full CREATE ... WRAPPED DDL and a bare body, located by the
  10g+ "a000000" marker, then the content-length line, then the base64 lines.

  DBMS_METADATA quoting and the add-CREATE-OR-REPLACE option are deferred to v2.
}

{$mode objfpc}{$H+}

interface

uses
  Classes,     // TStringList
  UnwrapCore;  // EUnwrapError / TUnwrapErrorKind

type
  { One wrapped object located in the input: the inclusive line range to replace
    (its CREATE..WRAPPED header line through the last base64 line) and the base64
    body to decode. }
  TWrapRegion = record
    HeadLine: Integer;
    LastLine: Integer;
    Body: AnsiString;
  end;
  TWrapRegionArray = array of TWrapRegion;

{ Every wrapped object found in Lines, in order. Raises EUnwrapError when
  nothing wrapped is present. Line indices refer to the passed-in Lines. }
function FindWrapRegions(Lines: TStringList): TWrapRegionArray;

{ All base64 wrap bodies in Text, one entry per wrapped object. Raises
  EUnwrapError when nothing wrapped is present. The caller owns the list. }
function ExtractBodies(const Text: AnsiString): TStringList;

{ The first wrapped body in Text (single-object convenience). }
function ExtractBody(const Text: AnsiString): AnsiString;

implementation

uses
  SysUtils;

const
  A000_MARKER = 'a000000';

function IsHexToken(const S: AnsiString): Boolean;
var
  I: Integer;
begin
  if Length(S) = 0 then
    Exit(False);
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
  Result := True;
end;

{ A content-length line: exactly two whitespace-separated hex numbers. }
function IsLenLine(const S: AnsiString): Boolean;
var
  T: AnsiString;
  P: Integer;
  Tok1, Tok2: AnsiString;
begin
  T := Trim(S);
  P := Pos(' ', T);
  if P = 0 then
    P := Pos(#9, T);
  if P = 0 then
    Exit(False);
  Tok1 := Trim(Copy(T, 1, P - 1));
  Tok2 := Trim(Copy(T, P + 1, Length(T)));
  Result := IsHexToken(Tok1) and IsHexToken(Tok2) and (Pos(' ', Tok2) = 0)
    and (Pos(#9, Tok2) = 0);
end;

{ A base64 payload line: [A-Za-z0-9+/] with optional trailing '=' padding. }
function IsB64Line(const S: AnsiString): Boolean;
var
  I: Integer;
  SeenPad: Boolean;
begin
  if Length(S) = 0 then
    Exit(False);
  SeenPad := False;
  for I := 1 to Length(S) do
  begin
    if S[I] = '=' then
      SeenPad := True
    else
    begin
      if SeenPad then
        Exit(False);  // data after padding
      if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/']) then
        Exit(False);
    end;
  end;
  Result := True;
end;

function ContainsWrapped(const Lines: TStringList): Boolean;
var
  I: Integer;
begin
  for I := 0 to Lines.Count - 1 do
    if Pos('wrapped', LowerCase(Lines[I])) > 0 then
      Exit(True);
  Result := False;
end;

{ Walk back from the 'a000000' marker to the object's CREATE...WRAPPED header
  line (a single line ending with the WRAPPED keyword) so it is replaced along
  with the body. Returns AIdx itself for a bare body with no such header. }
function FindHeaderStart(Lines: TStringList; AIdx: Integer): Integer;
var
  I: Integer;
  S: AnsiString;
begin
  Result := AIdx;
  I := AIdx - 1;
  while (I >= 0) and (Trim(Lines[I]) = '') do
    Dec(I);
  if I < 0 then
    Exit;
  S := LowerCase(Trim(Lines[I]));
  if (Length(S) >= 7) and (Copy(S, Length(S) - 6, 7) = 'wrapped') then
    Result := I;
end;

function FindWrapRegions(Lines: TStringList): TWrapRegionArray;
var
  I, J, LenIdx, LastB64, Count: Integer;
  S, Parts: AnsiString;
  HavePart, SawMarker: Boolean;
begin
  SetLength(Result, 0);
  Count := 0;
  SawMarker := False;

  I := 0;
  while I < Lines.Count do
  begin
    if LowerCase(Trim(Lines[I])) = A000_MARKER then
    begin
      SawMarker := True;

      // The content-length line for this block (stop if the next block starts).
      LenIdx := -1;
      for J := I + 1 to Lines.Count - 1 do
      begin
        if LowerCase(Trim(Lines[J])) = A000_MARKER then
          Break;
        if IsLenLine(Lines[J]) then
        begin
          LenIdx := J;
          Break;
        end;
      end;

      if LenIdx >= 0 then
      begin
        Parts := '';
        HavePart := False;
        LastB64 := LenIdx;
        for J := LenIdx + 1 to Lines.Count - 1 do
        begin
          S := Trim(Lines[J]);
          if S = '' then
          begin
            if HavePart then
              Break
            else
              Continue;
          end;
          if S = '/' then
            Break;
          if LowerCase(S) = A000_MARKER then
            Break;  // the next block starts here
          if IsB64Line(S) then
          begin
            Parts := Parts + S;
            HavePart := True;
            LastB64 := J;
          end
          else
            Break;
        end;

        if HavePart then
        begin
          SetLength(Result, Count + 1);
          Result[Count].HeadLine := FindHeaderStart(Lines, I);
          Result[Count].LastLine := LastB64;
          Result[Count].Body := Parts;
          Inc(Count);
        end;
      end;
    end;
    Inc(I);
  end;

  if Count = 0 then
  begin
    if not SawMarker then
    begin
      if ContainsWrapped(Lines) then
        raise EUnwrapError.CreateKind(uekLegacy,
          'no ''a000000'' marker found — this looks like the pre-10g (9i) ' +
          'wrap format, which is not supported')
      else
        raise EUnwrapError.CreateKind(uekNotWrapped, 'no wrapped body found');
    end
    else
      raise EUnwrapError.CreateKind(uekMalformed,
        'a wrapped marker was found but no base64 body could be extracted');
  end;
end;

function ExtractBodies(const Text: AnsiString): TStringList;
var
  Lines: TStringList;
  Regions: TWrapRegionArray;
  K: Integer;
begin
  Result := TStringList.Create;
  try
    Lines := TStringList.Create;
    try
      Lines.Text := Text;
      Regions := FindWrapRegions(Lines);   // raises if nothing wrapped
      for K := 0 to High(Regions) do
        Result.Add(Regions[K].Body);
    finally
      Lines.Free;
    end;
  except
    Result.Free;  // never leak the list when we bail out with an error
    raise;
  end;
end;

function ExtractBody(const Text: AnsiString): AnsiString;
var
  Bodies: TStringList;
begin
  Bodies := ExtractBodies(Text);
  try
    Result := Bodies[0];
  finally
    Bodies.Free;
  end;
end;

end.
