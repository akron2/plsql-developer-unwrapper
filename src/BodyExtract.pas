unit BodyExtract;

{
  Port of the relevant part of app/parser.py (_extract_base64), extended to
  batch.

  Given the text of a single editor window, locate the base64 wrap body of
  *every* wrapped object present. Handles the common shapes (full
  CREATE ... WRAPPED DDL and a bare body) by scanning for the 10g+ "a000000"
  marker, then the content-length line, then the base64 payload lines.

  Multiple objects in one window (a package spec + body, or several procedures)
  are all returned, so none is dropped silently. ExtractBody returns just the
  first body for callers (and tests) that handle a single object.

  DBMS_METADATA quoting and the add-CREATE-OR-REPLACE option are deferred to v2.
}

{$mode objfpc}{$H+}

interface

uses
  Classes,     // TStringList (return type of ExtractBodies)
  UnwrapCore;  // EUnwrapError / TUnwrapErrorKind

{ All base64 wrap bodies found in Text, one entry per wrapped object. Raises
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

{ Collect the base64 body of the wrapped block whose 'a000000' marker sits on
  line AIdx. Returns '' if this block has no usable length line / body (e.g. the
  next block's marker is reached first). }
function ExtractOne(Lines: TStringList; AIdx: Integer): AnsiString;
var
  LenIdx, I: Integer;
  S, Parts: AnsiString;
  HavePart: Boolean;
begin
  Result := '';

  LenIdx := -1;
  for I := AIdx + 1 to Lines.Count - 1 do
  begin
    if LowerCase(Trim(Lines[I])) = A000_MARKER then
      Exit;  // next block begins before a length line — this one is empty
    if IsLenLine(Lines[I]) then
    begin
      LenIdx := I;
      Break;
    end;
  end;
  if LenIdx < 0 then
    Exit;

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
    if LowerCase(S) = A000_MARKER then
      Break;  // the next block starts here
    if IsB64Line(S) then
    begin
      Parts := Parts + S;
      HavePart := True;
    end
    else
      Break;
  end;

  if HavePart then
    Result := Parts;
end;

function ExtractBodies(const Text: AnsiString): TStringList;
var
  Lines: TStringList;
  I: Integer;
  Body: AnsiString;
  SawMarker: Boolean;
begin
  Result := TStringList.Create;
  try
    Lines := TStringList.Create;
    try
      Lines.Text := Text;
      SawMarker := False;

      for I := 0 to Lines.Count - 1 do
        if LowerCase(Trim(Lines[I])) = A000_MARKER then
        begin
          SawMarker := True;
          Body := ExtractOne(Lines, I);
          if Body <> '' then
            Result.Add(Body);
        end;

      if Result.Count = 0 then
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
