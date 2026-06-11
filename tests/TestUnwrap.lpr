program TestUnwrap;

{
  Console test for the native core, mirroring tests/test_unwrap.py.

  The golden vector (a real Oracle-wrapped FUNCTION and its expected source) is
  generated from tests/test_unwrap.py into Golden.inc, so this validates the
  Pascal pipeline against genuine Oracle wrap output — and against the Python
  core — without a database.

  Build & run: plugin/tests/runtests.bat
}

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, UnwrapCore, BodyExtract;

{$I Golden.inc}

var
  Failures: Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('  PASS  ', Name)
  else
  begin
    WriteLn('  FAIL  ', Name);
    Inc(Failures);
  end;
end;

procedure TestGoldenVector;
var
  Src: AnsiString;
  Ok: Boolean;
begin
  try
    Src := DecodeBody(GOLDEN_B64, True, Ok);
    Check('golden_vector_source', Src = GOLDEN_SOURCE);
    Check('golden_vector_sha1', Ok);
  except
    on E: Exception do
    begin
      WriteLn('  FAIL  golden_vector raised ', E.ClassName, ': ', E.Message);
      Inc(Failures);
    end;
  end;
end;

procedure TestGoldenViaExtract;
var
  Body, Src: AnsiString;
  Ok: Boolean;
  Ddl: AnsiString;
  I: Integer;
begin
  // Wrap the golden body in a minimal CREATE ... WRAPPED DDL block.
  Ddl := 'CREATE OR REPLACE FUNCTION teste wrapped'#10'a000000'#10'1'#10;
  for I := 1 to 15 do
    Ddl := Ddl + 'abcd'#10;
  Ddl := Ddl + '8'#10'3d 71'#10 + GOLDEN_B64 + #10;
  try
    Body := ExtractBody(Ddl);
    Src := DecodeBody(Body, True, Ok);
    Check('golden_via_extract', (Src = GOLDEN_SOURCE) and Ok);
  except
    on E: Exception do
    begin
      WriteLn('  FAIL  golden_via_extract raised ', E.ClassName, ': ', E.Message);
      Inc(Failures);
    end;
  end;
end;

procedure TestPreservePlain;
// A plain (non-wrapped) package spec sitting next to a wrapped body: the
// wrapped block must be located precisely so the caller can swap it in place
// and keep the spec. Verifies the region span, not the rebuilt window text.
var
  Ddl: AnsiString;
  Lines: TStringList;
  Regions: TWrapRegionArray;
  Ok: Boolean;
  I: Integer;
begin
  Ddl := 'CREATE OR REPLACE PACKAGE demo AS'#10
       + '  PROCEDURE foo;'#10
       + 'END demo;'#10
       + '/'#10
       + 'CREATE OR REPLACE PACKAGE BODY demo wrapped'#10
       + 'a000000'#10'1'#10;
  for I := 1 to 15 do
    Ddl := Ddl + 'abcd'#10;
  Ddl := Ddl + '8'#10'3d 71'#10 + GOLDEN_B64 + #10'/'#10;

  Lines := TStringList.Create;
  try
    Lines.Text := Ddl;
    Regions := FindWrapRegions(Lines);
    Check('preserve_region_count', Length(Regions) = 1);
    Check('preserve_header_is_wrapped_create',
      (Length(Regions) = 1) and
      (Pos('package body demo', LowerCase(Lines[Regions[0].HeadLine])) > 0));
    Check('preserve_spec_outside_region',
      (Length(Regions) = 1) and (Regions[0].HeadLine >= 4) and
      (Pos('package demo as', LowerCase(Lines[0])) > 0));
    Check('preserve_body_decodes',
      (Length(Regions) = 1) and
      (DecodeBody(Regions[0].Body, True, Ok) = GOLDEN_SOURCE));
  finally
    Lines.Free;
  end;
end;

procedure TestNotWrapped;
begin
  try
    ExtractBody('SELECT * FROM dual;');
    Check('not_wrapped_raises', False);
  except
    on E: EUnwrapError do
      Check('not_wrapped_kind', E.Kind = uekNotWrapped);
  end;
end;

procedure TestLegacyStub;
begin
  try
    ExtractBody('CREATE OR REPLACE PROCEDURE old wrapped'#10'0'#10'ABCD1234DEADBEEF'#10);
    Check('legacy_raises', False);
  except
    on E: EUnwrapError do
      Check('legacy_kind', E.Kind = uekLegacy);
  end;
end;

procedure TestCharsetDetect;
var
  IsoBytes, CpBytes, Utf8Bytes: AnsiString;
begin
  // 'Это секретный код' as raw source bytes in three encodings. The ISO-8859-5
  // and cp1251 byte streams BOTH decode to valid Cyrillic — only the frequency
  // heuristic tells which is real Russian. (ACP-independent: we check the
  // inferred source code page, not the final host-ANSI bytes.)
  IsoBytes  := #$CD#$E2#$DE#$20#$E1#$D5#$DA#$E0#$D5#$E2#$DD#$EB#$D9#$20#$DA#$DE#$D4;
  CpBytes   := #$DD#$F2#$EE#$20#$F1#$E5#$EA#$F0#$E5#$F2#$ED#$FB#$E9#$20#$EA#$EE#$E4;
  Utf8Bytes := #$D0#$AD#$D1#$82#$D0#$BE;  // 'Это' in UTF-8
  Check('detect_iso8859p5', InferSourceCodePage(IsoBytes) = 28595);
  Check('detect_cp1251',    InferSourceCodePage(CpBytes) = 1251);
  Check('detect_utf8',      InferSourceCodePage(Utf8Bytes) = 65001);
end;

procedure TestSha1Tamper;
var
  B64: AnsiString;
  Ok: Boolean;
begin
  // Flip one character inside the golden base64 body to simulate tampering.
  B64 := GOLDEN_B64;
  if B64[10] = 'A' then
    B64[10] := 'B'
  else
    B64[10] := 'A';
  try
    DecodeBody(B64, True, Ok);
    Check('tamper_raises', False);
  except
    on E: EUnwrapError do
      Check('tamper_kind', (E.Kind = uekIntegrity) or (E.Kind = uekMalformed));
  end;
end;

begin
  WriteLn('TestUnwrap (native core)');
  TestGoldenVector;
  TestGoldenViaExtract;
  TestPreservePlain;
  TestNotWrapped;
  TestLegacyStub;
  TestCharsetDetect;
  TestSha1Tamper;
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL PASS')
  else
    WriteLn(Failures, ' FAILED');
  ExitCode := Ord(Failures <> 0);
end.
