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
  Windows, SysUtils, IdeApi, BodyExtract, UnwrapCore;

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

procedure DoUnwrap;
var
  Src, Body, Decoded: AnsiString;
  Sha1Ok: Boolean;
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
    Body := ExtractBody(Src);
    Decoded := DecodeBody(Body, True, Sha1Ok);
    IDE_CreateWindow(WT_SQL, PAnsiChar(Decoded), LongBool(False));
  except
    on E: EUnwrapError do
      MsgBox(E.Message, MB_ICONWARNING);
    on E: Exception do
      MsgBox('Unexpected error: ' + E.Message, MB_ICONERROR);
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
