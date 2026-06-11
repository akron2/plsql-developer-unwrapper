unit BodyExtract;

{
  MVP port of the relevant part of app/parser.py (_extract_base64).

  Given the text of a single editor window, locate and return the base64 wrap
  body. Handles the common shapes (full CREATE ... WRAPPED DDL and a bare body)
  by scanning for the 10g+ "a000000" marker, then the content-length line, then
  the base64 payload lines.

  v1 scope: a single object out of the active window. Batch (multiple objects),
  DBMS_METADATA quoting and the add-CREATE-OR-REPLACE option are deferred to v2.
}

{$mode objfpc}{$H+}

interface

uses
  UnwrapCore;  // EUnwrapError / TUnwrapErrorKind

function ExtractBody(const Text: AnsiString): AnsiString;

implementation

uses
  Classes, SysUtils;

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

function ExtractBody(const Text: AnsiString): AnsiString;
var
  Lines: TStringList;
  AIdx, LenIdx, I: Integer;
  S: AnsiString;
  Parts: AnsiString;
  HavePart: Boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Text;

    AIdx := -1;
    for I := 0 to Lines.Count - 1 do
      if LowerCase(Trim(Lines[I])) = A000_MARKER then
      begin
        AIdx := I;
        Break;
      end;

    if AIdx < 0 then
    begin
      if ContainsWrapped(Lines) then
        raise EUnwrapError.CreateKind(uekLegacy,
          'no ''a000000'' marker found — this looks like the pre-10g (9i) ' +
          'wrap format, which is not supported')
      else
        raise EUnwrapError.CreateKind(uekNotWrapped, 'no wrapped body found');
    end;

    LenIdx := -1;
    for I := AIdx + 1 to Lines.Count - 1 do
      if IsLenLine(Lines[I]) then
      begin
        LenIdx := I;
        Break;
      end;
    if LenIdx < 0 then
      raise EUnwrapError.CreateKind(uekMalformed,
        'could not locate the content-length line before the body');

    Parts := '';
    HavePart := False;
    for I := LenIdx + 1 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      if S = '' then
      begin
        if HavePart then
          Break
        else
          Continue;
      end;
      if S = '/' then
        Break;
      if IsB64Line(S) then
      begin
        Parts := Parts + S;
        HavePart := True;
      end
      else
        Break;
    end;

    if not HavePart then
      raise EUnwrapError.CreateKind(uekMalformed,
        'no base64 body found after the content-length line');

    Result := Parts;
  finally
    Lines.Free;
  end;
end;

end.
