unit PPMdVariantI;

{$mode objfpc}{$H+}
{$packrecords c}
{$inline on}

interface

uses
  Classes, SysUtils, CTypes, PPMdContext, PPMdSubAllocatorVariantI,
  CarrylessRangeCoder, PPMdSubAllocator, Math;

const
  MRM_RESTART = 0;
  MRM_CUT_OFF = 1;
  MRM_FREEZE = 2;

  UP_FREQ = 5;
  O_BOUND = 9;

type
  PPPMdModelVariantI = ^TPPMdModelVariantI;
  TPPMdModelVariantI = record
    core: TPPMdCoreModel;

    alloc: PPPMdSubAllocatorVariantI;

    NS2BSIndx: array[Byte] of cuint8; // constants
    QTable: array[0..259] of cuint8;  // constants

    MaxContext: PPPMdContext;
    MaxOrder, MRMethod: cint;
    SEE2Cont: array[0..23, 0..31] of TSEE2Context;
    DummySEE2Cont: TSEE2Context;
    BinSumm: array[0..24, 0..63] of cuint16; // binary SEE-contexts
  end;

function  CreatePPMdModelVariantI(input: PInStream;
    suballocsize: cint; maxorder: cint; restoration: cint): PPPMdModelVariantI; cdecl;
procedure FreePPMdModelVariantI(self: PPPMdModelVariantI); cdecl;

procedure StartPPMdModelVariantI(self: PPPMdModelVariantI; input: PInStream;
    alloc: PPPMdSubAllocatorVariantI; maxorder: cint; restoration: cint); cdecl;
function NextPPMdVariantIByte(self: PPPMdModelVariantI): cint; cdecl;

implementation

procedure RestartModel(self: PPPMdModelVariantI); forward;

procedure UpdateModel(self: PPPMdModelVariantI; mincontext: PPPMdContext); forward;
function CreateSuccessors(self: PPPMdModelVariantI; skip: cbool; p1: PPPMdState; mincontext: PPPMdContext): PPPMdContext; forward;
function ReduceOrder(self: PPPMdModelVariantI; state: PPPMdState; startcontext: PPPMdContext): PPPMdContext; forward;
procedure RestoreModel(self: PPPMdModelVariantI; currcontext, mincontext, FSuccessor: PPPMdContext); forward;

procedure ShrinkContext(self: PPPMdContext; newlastindex: cint; scale: cbool; model: PPPMdModelVariantI); forward;
function CutOffContext(self: PPPMdContext; order: cint; model: PPPMdModelVariantI): PPPMdContext; forward;
function RemoveBinConts(self: PPPMdContext; order: cint; model: PPPMdModelVariantI): PPPMdContext; forward;

procedure DecodeBinSymbolVariantI(self: PPPMdContext; model: PPPMdModelVariantI); forward;
procedure DecodeSymbol1VariantI(self: PPPMdContext; model: PPPMdModelVariantI); forward;
procedure DecodeSymbol2VariantI(self: PPPMdContext; model: PPPMdModelVariantI); forward;

procedure RescalePPMdContextVariantI(self: PPPMdContext; model: PPPMdModelVariantI); forward;

function CreatePPMdModelVariantI(input: PInStream; suballocsize: cint;
  maxorder: cint; restoration: cint): PPPMdModelVariantI; cdecl;
var
  self: PPPMdModelVariantI;
  alloc: PPPMdSubAllocatorVariantI;
begin
  self:= GetMem(sizeof(TPPMdModelVariantI));
  if (self = nil) then Exit(nil);
  alloc:= CreateSubAllocatorVariantI(suballocsize);
  if (alloc = nil) then
  begin
    FreeMem(self);
    Exit(nil);
  end;
  StartPPMdModelVariantI(self, input, alloc, maxorder, restoration);
  Result:= self;
end;

procedure FreePPMdModelVariantI(self: PPPMdModelVariantI); cdecl;
begin
  FreeMem(self^.alloc);
  FreeMem(self);
end;

procedure StartPPMdModelVariantI(self: PPPMdModelVariantI; input: PInStream;
  alloc: PPPMdSubAllocatorVariantI; maxorder: cint; restoration: cint); cdecl;
var
  pc: PPPMdContext;
  i, m, k, step: cint;
begin
  InitializeRangeCoder(@self^.core.coder, input, true, $8000);

  if (maxorder < 2) then // TODO: solid mode
  begin
    FillChar(self^.core.CharMask, sizeof(self^.core.CharMask), 0);
    self^.core.OrderFall:= self^.MaxOrder;
    pc:= self^.MaxContext;
    while (pc^.Suffix <> 0) do
    begin
      Dec(self^.core.OrderFall);
      pc:= PPMdContextSuffix(pc, @self^.core)
    end;
    Exit;
  end;

  self^.alloc:= alloc;
  self^.core.alloc:= @alloc^.core;

  Pointer(self^.core.RescalePPMdContext):= @RescalePPMdContextVariantI;

  self^.MaxOrder:= maxorder;
  self^.MRMethod:= restoration;
  self^.core.EscCount:= 1;

  self^.NS2BSIndx[0]:= 2 * 0;
  self^.NS2BSIndx[1]:= 2 * 1;
  for i:= 2 to 11 - 1 do self^.NS2BSIndx[i]:= 2 * 2;
  for i:= 11 to 256 - 1 do self^.NS2BSIndx[i]:= 2 * 3;

  for i:= 0 to UP_FREQ - 1 do self^.QTable[i]:= i;
  m:= UP_FREQ;
  k:= 1;
  step:= 1;
  for i:= UP_FREQ to 260 - 1 do
  begin
    self^.QTable[i]:= m;
    Dec(k);
    if (k = 0) then
    begin
      Inc(m); Inc(step); k:= step;
    end;
  end;

  self^.DummySEE2Cont.Summ:= $af8f;
  //self^.DummySEE2Cont.Shift:= $ac;
  self^.DummySEE2Cont.Count:= $84;
  self^.DummySEE2Cont.Shift:= PERIOD_BITS;

  RestartModel(self);
end;

procedure RestartModel(self: PPPMdModelVariantI);
const
  InitBinEsc: array[0..7] of cuint16 = ($3cdd,$1f3f,$59bf,$48f3,$64a1,$5abc,$6632,$6051);
var
  i, k, m: cint;
  maxstates: PPPMdState;
begin
  InitSubAllocator(self^.core.alloc);

  FillChar(self^.core.CharMask, sizeof(self^.core.CharMask), 0);

  self^.core.PrevSuccess:= 0;
  self^.core.OrderFall:= self^.MaxOrder;
  self^.core.InitRL:= -IfThen((self^.MaxOrder < 12), self^.MaxOrder, 12) - 1;
  self^.core.RunLength:= self^.core.InitRL;

  self^.MaxContext:= NewPPMdContext(@self^.core);
  self^.MaxContext^.LastStateIndex:= 255;
  self^.MaxContext^.SummFreq:= 257;
  self^.MaxContext^.States:= AllocUnits(self^.core.alloc, 256 div 2);

  maxstates:= PPMdContextStates(self^.MaxContext, @self^.core);
  for i:= 0 to 256 - 1 do
  begin
    maxstates[i].Symbol:= i;
    maxstates[i].Freq:= 1;
    maxstates[i].Successor:= 0;
  end;

  i:= 0;
  for m:= 0 to 25 - 1 do
  begin
    while (self^.QTable[i] = m) do Inc(i);
    for k:= 0 to 8 - 1 do self^.BinSumm[m, k]:= BIN_SCALE - InitBinEsc[k] div (i + 1);
    k:= 8;
    while (k < 64) do
    begin
     Move((@self^.BinSumm[m, 0])^, (@self^.BinSumm[m, k])^, 8 * sizeof(cuint16));
     k += 8;
   end;
  end;

  i:= 0;
  for m:= 0 to 24 - 1 do
  begin
    while (self^.QTable[i + 3] = m + 3) do Inc(i);
    for k:= 0 to 32 - 1 do self^.SEE2Cont[m, k]:= MakeSEE2(2 * i + 5, 7);
  end;
end;

function NextPPMdVariantIByte(self: PPPMdModelVariantI): cint; cdecl;
var
  byte: cuint8;
  mincontext: PPPMdContext;
begin
  mincontext:= self^.MaxContext;

  if (mincontext^.LastStateIndex <> 0) then DecodeSymbol1VariantI(mincontext, self)
  else DecodeBinSymbolVariantI(mincontext, self);

  while (self^.core.FoundState <> nil) do
  begin
    repeat
      Inc(self^.core.OrderFall);
      mincontext:= PPMdContextSuffix(mincontext, @self^.core);
      if (mincontext = nil) then Exit(-1);
    until not (mincontext^.LastStateIndex = self^.core.LastMaskIndex);

    DecodeSymbol2VariantI(mincontext, self);
  end;

  byte:= self^.core.FoundState^.Symbol;

  if (self^.core.OrderFall = 0) and (pcuint8(PPMdStateSuccessor(self^.core.FoundState, @self^.core)) >= self^.alloc^.UnitsStart) then
  begin
    self^.MaxContext:= PPMdStateSuccessor(self^.core.FoundState, @self^.core);
    //PrefetchData(MaxContext)
  end
  else
  begin
    UpdateModel(self, mincontext);
    //PrefetchData(MaxContext)
    if (self^.core.EscCount = 0) then ClearPPMdModelMask(@self^.core);
  end;

  Result:= byte;
end;

procedure UpdateModel(self: PPPMdModelVariantI; mincontext: PPPMdContext);
label
  RESTART_MODEL;
var
  flag: cuint8;
  fs: TPPMdState;
  states: cuint32;
  minnum, s0, currnum: cint;
  cf, sf, freq: cuint;
  currstates, new: PPPMdState;
  state: PPPMdState = nil;
  context, currcontext,
  Successor, newsuccessor: PPPMdContext;
begin
	fs:= self^.core.FoundState^;
	currcontext:= self^.MaxContext;

	if (fs.Freq < MAX_FREQ div 4) and (mincontext^.Suffix) then
	begin
		context:= PPMdContextSuffix(mincontext, @self^.core);
		if (context^.LastStateIndex <> 0) then
		begin
			state:= PPMdContextStates(context, @self^.core);

			if (state^.Symbol <> fs.Symbol) then
			begin
				repeat Inc(state);
				until not (state^.Symbol <> fs.Symbol);

				if (state[0].Freq >= state[-1].Freq) then
				begin
					SWAP(state[0], state[-1]);
					Dec(state);
				end;
			end;

			if (state^.Freq < MAX_FREQ - 9) then
			begin
				state^.Freq + =2;
				context^.SummFreq + =2;
			end;
		end;
		else
		begin
			state:= PPMdContextOneState(context);
			if (state^.Freq < 32) then Inc(state^.Freq);
		end;
	end;

	if (self^.core.OrderFall = 0) and (fs.Successor) then
	begin
		newsuccessor:= CreateSuccessors(self, true, state, mincontext);
		SetPPMdStateSuccessorPointer(self^.core.FoundState, newsuccessor, @self^.core);
		if (newsuccessor = nil) then goto RESTART_MODEL;
		self^.MaxContext:= newsuccessor;
		Exit;
	end;

	self^.alloc^.pText^:= fs.Symbol; Inc(self^.alloc^.pText);
	Successor:= PPPMdContext(self^.alloc^.pText);

	if (self^.alloc^.pText >= self^.alloc^.UnitsStart) then goto RESTART_MODEL;

	if (fs.Successor <> nil) then
	begin
		if pcuint8(PPMdStateSuccessor(@fs, @self^.core)) < self^.alloc^.UnitsStart then
		begin
			SetPPMdStateSuccessorPointer(@fs, CreateSuccessors(self, false, state, mincontext), @self^.core);
		end;
	end
	else
	begin
		SetPPMdStateSuccessorPointer(@fs, ReduceOrder(self, state, mincontext), @self^.core);
	end;

	if (fs.Successor = nil) then goto RESTART_MODEL;

        Dec(self^.core.OrderFall);
        if (self^.core.OrderFall = 0) then
	begin
		Successor:= PPMdStateSuccessor(@fs, @self^.core);
		if (self^.MaxContext <> mincontext) then Dec(self^.alloc^.pText);
	end
	else if (self^.MRMethod > MRM_FREEZE) then
	begin
		Successor:= PPMdStateSuccessor(@fs, @self^.core);
		self^.alloc^.pText:= self^.alloc^.HeapStart;
		self^.core.OrderFall:= 0;
	end;

	minnum:= mincontext^.LastStateIndex + 1;
	s0:= mincontext^.SummFreq - minnum - (fs.Freq - 1);
	flag:= IfThen(fs.Symbol >= $40, 8, 0);

        while (currcontext <> mincontext) do
	begin
		currnum:= currcontext^.LastStateIndex + 1;
		if (currnum <> 1) then
		begin
			if ((currnum and 1) = 0) then
			begin
				states:= ExpandUnits(self^.core.alloc, currcontext^.States, currnum shr 1);
				if (states = 0) then goto RESTART_MODEL;
				currcontext^.States:= states;
			end;
			if (3 * currnum - 1 < minnum) then Inc(currcontext^.SummFreq);
		end
		else
		begin
			PPMdState *states=OffsetToPointer(self^.core.alloc,AllocUnits(self^.core.alloc,1));
			if (states = nil) then goto RESTART_MODEL;
			states[0]:= PPMdContextOneState(currcontext)^;
			SetPPMdContextStatesPointer(currcontext, states, @self^.core);

			if (states[0].Freq < MAX_FREQ div 4 - 1) then states[0].Freq *= 2;
			else states[0].Freq:= MAX_FREQ - 4;

			currcontext^.SummFreq:= states[0].Freq + self^.core.InitEsc + IfThen(minnum > 3, 1, 0);
		end;

		cf:= 2 * fs.Freq * (currcontext^.SummFreq + 6);
		sf:= s0 + currcontext^.SummFreq;


		if (cf < 6 * sf) then
		begin
			if (cf >= 4 * sf) then freq:= 3;
			else if (cf > sf) then freq:= 2;
			else freq:= 1;
			currcontext^.SummFreq += 4;
		end
		else
		begin
			if (cf > 15 * sf) then freq:= 7;
			else if (cf > 12 * sf) then freq:= 6;
			else if (cf > 9 * sf) then freq:= 5;
			else freq:= 4;
			currcontext^.SummFreq += freq;
		end;

		Inc(currcontext^.LastStateIndex);
		currstates:= PPMdContextStates(currcontext, @self^.core);
		new:= @currstates[currcontext^.LastStateIndex];
		SetPPMdStateSuccessorPointer(new, Successor, @self^.core);
		new^.Symbol:= fs.Symbol;
		new^.Freq:= freq;
		currcontext^.Flags:= currcontext^.Flags or flag;
        currcontext:= PPMdContextSuffix(currcontext, @self^.core)
        end;

	self^.MaxContext:= PPMdStateSuccessor(@fs, @self^.core);

	Exit;

	RESTART_MODEL:
	RestoreModel(self, currcontext, mincontext, PPMdStateSuccessor(@fs, @self^.core));
end;

function CreateSuccessors(self: PPPMdModelVariantI; skip: cbool; p1: PPPMdState; mincontext: PPPMdContext): PPPMdContext;
begin

end;

function ReduceOrder(self: PPPMdModelVariantI; state: PPPMdState; startcontext: PPPMdContext): PPPMdContext;
begin

end;

procedure RestoreModel(self: PPPMdModelVariantI; currcontext, mincontext, FSuccessor: PPPMdContext);
begin

end;

procedure ShrinkContext(self: PPPMdContext; newlastindex: cint; scale: cbool; model: PPPMdModelVariantI);
var
  i, escfreq: cint;
  states: PPPMdState;
begin
  self^.States:= ShrinkUnits(model^.core.alloc, self^.States, (self^.LastStateIndex + 2) shr 1, (newlastindex + 2) shr 1);
  self^.LastStateIndex:= newlastindex;

  if (scale) then self^.Flags:= self^.Flags and $14
  else self^.Flags:= self^.Flags and $10;

  states:= PPMdContextStates(self, @model^.core);
  escfreq:= self^.SummFreq;
  self^.SummFreq:= 0;

  for i:= 0 to self^.LastStateIndex do
  begin
    escfreq -= states[i].Freq;
    if (scale) then states[i].Freq:= (states[i].Freq + 1) shr 1;
    self^.SummFreq += states[i].Freq;
    if (states[i].Symbol >= $40) then self^.Flags:= self^.Flags or $08;
  end;

  if (scale) then escfreq:= (escfreq + 1) shr 1;

  self^.SummFreq += escfreq;
end;

function CutOffContext(self: PPPMdContext; order: cint; model: PPPMdModelVariantI): PPPMdContext;
begin

end;

function RemoveBinConts(self: PPPMdContext; order: cint; model: PPPMdModelVariantI): PPPMdContext;
begin

end;

procedure DecodeBinSymbolVariantI(self: PPPMdContext; model: PPPMdModelVariantI);
var
  bs: pcuint16;
  index: cuint8;
  rs: PPPMdState;
begin
  rs:= PPMdContextOneState(self);

  index:= model^.NS2BSIndx[PPMdContextSuffix(self, @model^.core)^.LastStateIndex] + model^.core.PrevSuccess + self^.Flags;
  bs:= @model^.BinSumm[model^.QTable[rs^.Freq - 1], index + ((model^.core.RunLength shr 26) and $20)];

  PPMdDecodeBinSymbol(self, @model^.core, bs, 196, false);
end;

procedure DecodeSymbol1VariantI(self: PPPMdContext; model: PPPMdModelVariantI);
begin
  PPMdDecodeSymbol1(self, @model^.core, true);
end;

procedure DecodeSymbol2VariantI(self: PPPMdContext; model: PPPMdModelVariantI);
begin

end;

procedure RescalePPMdContextVariantI(self: PPPMdContext; model: PPPMdModelVariantI);
begin

end;

end.

