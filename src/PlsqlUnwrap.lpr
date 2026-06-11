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

{ Decode every wrapped object in the active window into one new SQL window.
  One object''s failure never blocks the others — it becomes an inline comment,
  so nothing is dropped silently. }
procedure DoUnwrap;
var
  Src, Decoded, Output, Msg: AnsiString;
  Bodies: TStringList;
  Sha1Ok, Lossy, AnyLossy: Boolean;
  I, OkCount, FailCount: Integer;
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

  try
    Bodies := ExtractBodies(Src);
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

  try
    if Bodies.Count = 1 then
    begin
      // Single object: keep the original UX — a failure is reported in a dialog
      // and nothing is opened.
      try
        Decoded := DecodeBody(Bodies[0], True, Sha1Ok, Lossy);
        IDE_CreateWindow(WT_SQL, PAnsiChar(Decoded), LongBool(False));
        if Lossy then
          MsgBox('Unwrapped, but with a caveat: ' + LOSSY_NOTE, MB_ICONWARNING);
      except
        on E: EUnwrapError do
          MsgBox(E.Message, MB_ICONWARNING);
        on E: Exception do
          MsgBox('Unexpected error: ' + E.Message, MB_ICONERROR);
      end;
    end
    else
    begin
      // Multiple objects: unwrap every one into a single new window. Each one is
      // labelled; a failure becomes an inline SQL comment rather than aborting.
      Output := '';
      OkCount := 0;
      FailCount := 0;
      AnyLossy := False;
      for I := 0 to Bodies.Count - 1 do
      begin
        if I > 0 then
          Output := Output + LineEnding + LineEnding;
        Output := Output + Format('-- ===== Object %d of %d =====',
          [I + 1, Bodies.Count]) + LineEnding;
        try
          Decoded := DecodeBody(Bodies[I], True, Sha1Ok, Lossy);
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
      end;

      IDE_CreateWindow(WT_SQL, PAnsiChar(Output), LongBool(False));

      if (FailCount > 0) or AnyLossy then
      begin
        Msg := Format('%d of %d objects unwrapped, %d failed.',
          [OkCount, Bodies.Count, FailCount]);
        if FailCount > 0 then
          Msg := Msg + ' Failures are shown as comments in the new window.';
        if AnyLossy then
          Msg := Msg + ' ' + LOSSY_NOTE;
        MsgBox(Msg, MB_ICONWARNING);
      end;
    end;
  finally
    Bodies.Free;
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
