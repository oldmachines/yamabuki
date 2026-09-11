#!/usr/bin/env python3
"""Super Metroid decompressor ($80:B0FF) port — see docs/SM_SA1_FINDINGS.md §5.

Usage as a module: from sm_decomp import decomp, off
  off(bank, addr)      -> LoROM file offset of $bank:addr (headerless image)
  decomp(image, off)   -> (bytes, end_offset)
"""
import struct
def off(bank,a): return (bank&0x7F)*0x8000+(a-0x8000)
def decomp(img, o):
    out=bytearray(); i=o
    while True:
        b=img[i]; i+=1
        if b==0xFF: return bytes(out), i
        cmd=b>>5; ln=(b&0x1F)+1
        if cmd==7:
            cmd=(b>>2)&7; ln=((b&3)<<8|img[i])+1; i+=1
        if cmd==0: out+=img[i:i+ln]; i+=ln
        elif cmd==1: out+=bytes([img[i]])*ln; i+=1
        elif cmd==2: out+=(img[i:i+2]*(ln//2+1))[:ln]; i+=2
        elif cmd==3:
            v=img[i]; i+=1; out+=bytes([(v+k)&0xFF for k in range(ln)])
        elif cmd in (4,5):
            p=img[i]|img[i+1]<<8; i+=2
            for k in range(ln): out.append(out[p+k]^(0xFF if cmd==5 else 0))
        elif cmd in (6,7):
            d=img[i]; i+=1; p=len(out)-d
            for k in range(ln): out.append(out[p+k]^(0xFF if cmd==7 else 0))
