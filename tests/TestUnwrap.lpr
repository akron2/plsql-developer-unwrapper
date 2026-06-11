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
  SysUtils, UnwrapCore, BodyExtract;

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
  TestNotWrapped;
  TestLegacyStub;
  TestSha1Tamper;
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL PASS')
  else
    WriteLn(Failures, ' FAILED');
  ExitCode := Ord(Failures <> 0);
end.
