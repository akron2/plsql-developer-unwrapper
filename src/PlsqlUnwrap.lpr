library PlsqlUnwrap;

{
  PL/SQL Developer plug-in: unwrap the wrapped (10g+) PL/SQL object in the
  active SQL window and open the source in a new SQL window. Fully offline:
  no database, no network. Wrap is obfuscation, not encryption.

  All exported functions use the C++ calling convention (cdecl) and ANSI
  strings (PAnsiChar), as required by the Plug-In interface. Returned PChar
  buffers are kept alive in module-level variables so they survive the call.

  Build: see plugin/build/build32.bat and build64.bat (they regenerate the
  CHARMAP include from app/unwrap.py first).
}

{$mode objfpc}{$H+}

uses
  Windows, Classes, SysUtils, IdeApi, BodyExtract, UnwrapCore;

const
  PLUGIN_NAME = 'PL/SQL Unwrapper';
  MENU_UNWRAP = 1;

var
  GName:  AnsiString;
  GMenu:  AnsiString;
  GAbout: AnsiString;
  GPluginId: Integer = 0;

procedure MsgBox(const Text: AnsiString; Icon: UINT);
begin
  MessageBoxA(0, PAnsiChar(Text), PLUGIN_NAME, MB_OK or Icon);
end;

function IdentifyPlugIn(ID: Integer): PAnsiChar; cdecl;
begin
  GPluginId := ID;
  GName := PLUGIN_NAME;
  Result := PAnsiChar(GName);
end;

function CreateMenuItem(Index: Integer): PAnsiChar; cdecl;
begin
  GMenu := '';
  case Index of
    MENU_UNWRAP: GMenu := 'Tools / Unwrap &Source';
  end;
  Result := PAnsiChar(GMenu);
end;

procedure RegisterCallback(Index: Integer; Addr: Pointer); cdecl;
begin
  StoreCallback(Index, Addr);
end;

function About: PAnsiChar; cdecl;
begin
  GAbout := PLUGIN_NAME + ' — offline Oracle PL/SQL unwrap (10g+). ' +
    'Wrap is obfuscation, not encryption.';
  Result := PAnsiChar(GAbout);
end;

const
  LOSSY_NOTE = 'Some characters have no representation in the host ANSI code '
    + 'page and were shown as "?". The source likely uses a database character '
    + 'set wider than this Windows code page.';

{ Replace every wrapped object in the active window with its unwrapped source,
  in place, leaving all non-wrapped text untouched — a plain package spec next
  to a wrapped body (or vice versa) is preserved verbatim, so nothing is lost.
  The whole transformed text goes to one new SQL window. A failed object becomes
  an inline comment where its block was, and never blocks the rest. }
procedure DoUnwrap;
var
  Src, Decoded, Output, Msg: AnsiString;
  Lines: TStringList;
  Regions: TWrapRegionArray;
  Sha1Ok, Lossy, AnyLossy: Boolean;
  I, R, OkCount, FailCount: Integer;
begin
  if (not Assigned(IDE_GetText)) or (not Assigned(IDE_CreateWindow)) then
  begin
    MsgBox('Plug-in is not fully initialized by the host.', MB_ICONERROR);
    Exit;
  end;

  Src := AnsiString(IDE_GetText());
  if Trim(Src) = '' then
  begin
    MsgBox('The active window is empty — nothing to unwrap.', MB_ICONINFORMATION);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    Lines.Text := Src;

    try
      Regions := FindWrapRegions(Lines);
    except
      on E: EUnwrapError do
      begin
        MsgBox(E.Message, MB_ICONWARNING);
        Exit;
      end;
      on E: Exception do
      begin
        MsgBox('Unexpected error: ' + E.Message, MB_ICONERROR);
        Exit;
      end;
    end;

    // Rebuild the window text: emit each line verbatim, except that a wrapped
    // block (header..last base64 line) is swapped for its unwrapped source.
    Output := '';
    OkCount := 0;
    FailCount := 0;
    AnyLossy := False;
    R := 0;
    I := 0;
    while I < Lines.Count do
    begin
      if (R <= High(Regions)) and (I = Regions[R].HeadLine) then
      begin
        try
          Decoded := DecodeBody(Regions[R].Body, True, Sha1Ok, Lossy);
          Output := Output + Decoded;
          AnyLossy := AnyLossy or Lossy;
          Inc(OkCount);
        except
          on E: EUnwrapError do
          begin
            Output := Output + '-- ' + E.Message;
            Inc(FailCount);
          end;
          on E: Exception do
          begin
            Output := Output + '-- Unexpected error: ' + E.Message;
            Inc(FailCount);
          end;
        end;
        I := Regions[R].LastLine + 1;   // skip the consumed wrapped block
        Inc(R);
        if I < Lines.Count then
          Output := Output + LineEnding;
      end
      else
      begin
        Output := Output + Lines[I];
        if I < Lines.Count - 1 then
          Output := Output + LineEnding;
        Inc(I);
      end;
    end;

    IDE_CreateWindow(WT_SQL, PAnsiChar(Output), LongBool(False));

    if (FailCount > 0) or AnyLossy then
    begin
      Msg := Format('%d of %d wrapped object(s) unwrapped, %d failed.',
        [OkCount, Length(Regions), FailCount]);
      if FailCount > 0 then
        Msg := Msg + ' Failures are shown as comments in the new window.';
      if AnyLossy then
        Msg := Msg + ' ' + LOSSY_NOTE;
      MsgBox(Msg, MB_ICONWARNING);
    end;
  finally
    Lines.Free;
  end;
end;

procedure OnMenuClick(Index: Integer); cdecl;
begin
  case Index of
    MENU_UNWRAP: DoUnwrap;
  end;
end;

exports
  IdentifyPlugIn,
  CreateMenuItem,
  RegisterCallback,
  OnMenuClick,
  About;

begin
end.
