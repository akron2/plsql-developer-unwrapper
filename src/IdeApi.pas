unit IdeApi;

{
  Bridge to the PL/SQL Developer host.

  The host hands us function pointers one at a time through the exported
  RegisterCallback function, each tagged with a fixed Index. We keep only the
  few we need for unwrap. Indices, signatures, calling convention and types are
  taken verbatim from the official "PL/SQL Developer Plug-In interface
  Documentation":

    * C++ calling convention (cdecl) for ALL exports and callbacks;
    * parameters limited to Integer (32-bit), Bool (32-bit -> LongBool) and
      zero-terminated strings (char* -> PAnsiChar).
}

{$mode objfpc}{$H+}

interface

const
  // RegisterCallback indices (from the API doc).
  CB_IDE_GETWINDOWTYPE   = 14;
  CB_IDE_CREATEWINDOW    = 20;
  CB_IDE_GETTEXT         = 30;
  CB_IDE_GETSELECTEDTEXT = 31;

  // Window types returned by IDE_GetWindowType / accepted by IDE_CreateWindow.
  WT_SQL       = 1;
  WT_TEST      = 2;
  WT_PROCEDURE = 3;
  WT_COMMAND   = 4;
  WT_PLAN      = 5;
  WT_REPORT    = 6;

type
  TIdeGetWindowType   = function: Integer; cdecl;
  TIdeGetText         = function: PAnsiChar; cdecl;
  TIdeGetSelectedText = function: PAnsiChar; cdecl;
  TIdeCreateWindow    = procedure(WindowType: Integer; Text: PAnsiChar;
                          Execute: LongBool); cdecl;

var
  IDE_GetWindowType:   TIdeGetWindowType   = nil;
  IDE_GetText:         TIdeGetText         = nil;
  IDE_GetSelectedText: TIdeGetSelectedText = nil;
  IDE_CreateWindow:    TIdeCreateWindow    = nil;

{ Called from the exported RegisterCallback for every host callback. }
procedure StoreCallback(Index: Integer; Addr: Pointer);

implementation

procedure StoreCallback(Index: Integer; Addr: Pointer);
begin
  case Index of
    CB_IDE_GETWINDOWTYPE:   IDE_GetWindowType   := TIdeGetWindowType(Addr);
    CB_IDE_CREATEWINDOW:    IDE_CreateWindow    := TIdeCreateWindow(Addr);
    CB_IDE_GETTEXT:         IDE_GetText         := TIdeGetText(Addr);
    CB_IDE_GETSELECTEDTEXT: IDE_GetSelectedText := TIdeGetSelectedText(Addr);
  end;
end;

end.
