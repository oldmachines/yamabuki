#!/usr/bin/env python3
"""Minimal 65816 disassembler for reading SNES ROM call sites.

  python tools/dis65816.py image.sfc 82 E7B1 D0 mx

bank/addr/len in hex; the optional last arg lists which of M/X start as 8-bit
(REP/SEP are tracked from there). Headerless LoROM images only.
"""
import sys
# minimal 65816 disassembler. mode strings: imm8/immM/immX, dp, dpx, dpy, abs, absx, absy, absl, abslx, ind, indx, indy, indl, indly, sr, sry, rel, rell, blk, impl, acc, dpi, abl(jml)
OPS={}
def d(op,name,mode): OPS[op]=(name,mode)
tbl=[ # standard ALU ops
 ("ORA",0x00),("AND",0x20),("EOR",0x40),("ADC",0x60),("STA",0x80),("LDA",0xA0),("CMP",0xC0),("SBC",0xE0)]
for n,b in tbl:
    for lo,mode in [(0x01,"indx"),(0x03,"sr"),(0x05,"dp"),(0x07,"indl"),(0x09,"immM"),(0x0D,"abs"),(0x0F,"absl"),(0x11,"indy"),(0x12,"dpi"),(0x13,"sry"),(0x15,"dpx"),(0x17,"indly"),(0x19,"absy"),(0x1D,"absx"),(0x1F,"abslx")]:
        d(b|lo,n,mode)
del OPS[0x89]; d(0x89,"BIT","immM")
for n,b in [("ASL",0x00),("ROL",0x20),("LSR",0x40),("ROR",0x60)]:
    d(b|0x06,n,"dp"); d(b|0x0A,n,"acc"); d(b|0x0E,n,"abs"); d(b|0x16,n,"dpx"); d(b|0x1E,n,"absx")
for op,n,m in [(0xE6,"INC","dp"),(0xEE,"INC","abs"),(0xF6,"INC","dpx"),(0xFE,"INC","absx"),(0x1A,"INC","acc"),(0xC6,"DEC","dp"),(0xCE,"DEC","abs"),(0xD6,"DEC","dpx"),(0xDE,"DEC","absx"),(0x3A,"DEC","acc"),
 (0xA2,"LDX","immX"),(0xA6,"LDX","dp"),(0xAE,"LDX","abs"),(0xB6,"LDX","dpy"),(0xBE,"LDX","absy"),(0xA0,"LDY","immX"),(0xA4,"LDY","dp"),(0xAC,"LDY","abs"),(0xB4,"LDY","dpx"),(0xBC,"LDY","absx"),
 (0x86,"STX","dp"),(0x8E,"STX","abs"),(0x96,"STX","dpy"),(0x84,"STY","dp"),(0x8C,"STY","abs"),(0x94,"STY","dpx"),(0x64,"STZ","dp"),(0x74,"STZ","dpx"),(0x9C,"STZ","abs"),(0x9E,"STZ","absx"),
 (0xE0,"CPX","immX"),(0xE4,"CPX","dp"),(0xEC,"CPX","abs"),(0xC0,"CPY","immX"),(0xC4,"CPY","dp"),(0xCC,"CPY","abs"),(0x24,"BIT","dp"),(0x2C,"BIT","abs"),(0x34,"BIT","dpx"),(0x3C,"BIT","absx"),
 (0x04,"TSB","dp"),(0x0C,"TSB","abs"),(0x14,"TRB","dp"),(0x1C,"TRB","abs"),
 (0x10,"BPL","rel"),(0x30,"BMI","rel"),(0x50,"BVC","rel"),(0x70,"BVS","rel"),(0x80,"BRA","rel"),(0x90,"BCC","rel"),(0xB0,"BCS","rel"),(0xD0,"BNE","rel"),(0xF0,"BEQ","rel"),(0x82,"BRL","rell"),
 (0x4C,"JMP","abs"),(0x5C,"JML","absl"),(0x6C,"JMP","(abs)"),(0x7C,"JMP","(abs,x)"),(0xDC,"JML","[abs]"),(0x20,"JSR","abs"),(0x22,"JSL","absl"),(0xFC,"JSR","(abs,x)"),
 (0x60,"RTS","impl"),(0x6B,"RTL","impl"),(0x40,"RTI","impl"),(0x00,"BRK","imm8"),(0x02,"COP","imm8"),(0x42,"WDM","imm8"),
 (0xC2,"REP","imm8"),(0xE2,"SEP","imm8"),(0x18,"CLC","impl"),(0x38,"SEC","impl"),(0x58,"CLI","impl"),(0x78,"SEI","impl"),(0xB8,"CLV","impl"),(0xD8,"CLD","impl"),(0xF8,"SED","impl"),(0xFB,"XCE","impl"),
 (0x48,"PHA","impl"),(0x68,"PLA","impl"),(0xDA,"PHX","impl"),(0xFA,"PLX","impl"),(0x5A,"PHY","impl"),(0x7A,"PLY","impl"),(0x08,"PHP","impl"),(0x28,"PLP","impl"),(0x8B,"PHB","impl"),(0xAB,"PLB","impl"),(0x0B,"PHD","impl"),(0x2B,"PLD","impl"),(0x4B,"PHK","impl"),
 (0xF4,"PEA","abs"),(0xD4,"PEI","dp"),(0x62,"PER","rell"),
 (0xAA,"TAX","impl"),(0xA8,"TAY","impl"),(0x8A,"TXA","impl"),(0x98,"TYA","impl"),(0x9A,"TXS","impl"),(0xBA,"TSX","impl"),(0x9B,"TXY","impl"),(0xBB,"TYX","impl"),(0x5B,"TCD","impl"),(0x7B,"TDC","impl"),(0x1B,"TCS","impl"),(0x3B,"TSC","impl"),
 (0xE8,"INX","impl"),(0xC8,"INY","impl"),(0xCA,"DEX","impl"),(0x88,"DEY","impl"),(0xEA,"NOP","impl"),(0xEB,"XBA","impl"),(0xCB,"WAI","impl"),(0xDB,"STP","impl"),
 (0x54,"MVN","blk"),(0x44,"MVP","blk")]:
    d(op,n,m)
def dis(img, off, addr, n, m8=True, x8=True, bank=0):
    out=[]; i=off; a=addr; end=off+n
    while i<end:
        op=img[i]; name,mode=OPS.get(op,("???","impl"))
        if mode=="immM": L=1 if m8 else 2
        elif mode=="immX": L=1 if x8 else 2
        else: L={"imm8":1,"dp":1,"dpx":1,"dpy":1,"abs":2,"absx":2,"absy":2,"absl":3,"abslx":3,"ind":2,"indx":1,"indy":1,"indl":1,"indly":1,"sr":1,"sry":1,"rel":1,"rell":2,"blk":2,"impl":0,"acc":0,"dpi":1,"(abs)":2,"(abs,x)":2,"[abs]":2}[mode]
        ops=img[i+1:i+1+L]; v=int.from_bytes(ops,'little') if L else 0
        if mode in("rel",): tgt=(a+2+(v-256 if v>127 else v))&0xFFFF; s="$%04X"%tgt
        elif mode=="rell": tgt=(a+3+(v-65536 if v>32767 else v))&0xFFFF; s="$%04X"%tgt
        elif mode in("immM","immX","imm8"): s="#$%0*X"%(L*2,v)
        elif mode=="dp": s="$%02X"%v
        elif mode=="dpx": s="$%02X,X"%v
        elif mode=="dpy": s="$%02X,Y"%v
        elif mode=="abs": s="$%04X"%v
        elif mode=="absx": s="$%04X,X"%v
        elif mode=="absy": s="$%04X,Y"%v
        elif mode=="absl": s="$%02X:%04X"%(v>>16,v&0xFFFF)
        elif mode=="abslx": s="$%02X:%04X,X"%(v>>16,v&0xFFFF)
        elif mode=="indx": s="($%02X,X)"%v
        elif mode=="indy": s="($%02X),Y"%v
        elif mode=="dpi": s="($%02X)"%v
        elif mode=="indl": s="[$%02X]"%v
        elif mode=="indly": s="[$%02X],Y"%v
        elif mode=="sr": s="$%02X,S"%v
        elif mode=="sry": s="($%02X,S),Y"%v
        elif mode=="blk": s="$%02X,$%02X"%(v&0xFF,v>>8)
        elif mode=="(abs)": s="($%04X)"%v
        elif mode=="(abs,x)": s="($%04X,X)"%v
        elif mode=="[abs]": s="[$%04X]"%v
        elif mode=="acc": s="A"
        else: s=""
        out.append("%02X:%04X  %-12s %s %s"%(bank,a,img[i:i+1+L].hex(),name,s))
        if name=="REP": 
            if v&0x20: m8=False
            if v&0x10: x8=False
        if name=="SEP":
            if v&0x20: m8=True
            if v&0x10: x8=True
        i+=1+L; a+=1+L
    return out
if __name__=="__main__":
    img=open(sys.argv[1],'rb').read(); bank=int(sys.argv[2],16); addr=int(sys.argv[3],16); n=int(sys.argv[4],16)
    m8=len(sys.argv)<6 or 'M' in sys.argv[5]; x8=len(sys.argv)<6 or 'X' in sys.argv[5]
    o=(bank&0x7F)*0x8000+(addr-0x8000)
    print("\n".join(dis(img,o,addr,n,m8,x8,bank)))
