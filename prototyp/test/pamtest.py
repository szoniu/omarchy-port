#!/usr/bin/env python3
"""Minimalny pamtester (ctypes → libpam): pamtest.py <usługa> <użytkownik> <hasło>
Wypisuje kod pam_authenticate i komunikat. Tylko do diagnozy w VM prototypu."""
import ctypes, ctypes.util, sys

libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
libc = ctypes.CDLL(ctypes.util.find_library("c"))
libc.calloc.restype = ctypes.c_void_p
libc.strdup.restype = ctypes.c_void_p
libc.strdup.argtypes = [ctypes.c_char_p]

class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]

class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]

CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(PamMessage)),
                        ctypes.POINTER(ctypes.POINTER(PamResponse)), ctypes.c_void_p)

class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV), ("appdata_ptr", ctypes.c_void_p)]

service, user, password = sys.argv[1], sys.argv[2], sys.argv[3]

def conv(n, msgs, resp, _):
    arr = libc.calloc(n, ctypes.sizeof(PamResponse))
    resp[0] = ctypes.cast(arr, ctypes.POINTER(PamResponse))
    for i in range(n):
        style = msgs[i].contents.msg_style
        text = (msgs[i].contents.msg or b"").decode(errors="replace")
        if style == 1:  # PAM_PROMPT_ECHO_OFF
            resp[0][i].resp = libc.strdup(password.encode())
        else:
            print(f"  [PAM msg styl={style}] {text}")
    return 0

handle = ctypes.c_void_p()
c = PamConv(CONV(conv), None)
libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
libpam.pam_strerror.restype = ctypes.c_char_p
r = libpam.pam_start(service.encode(), user.encode(), ctypes.byref(c), ctypes.byref(handle))
r = libpam.pam_authenticate(handle, 0)
print(f"pam_authenticate rc={r} ({libpam.pam_strerror(handle, r).decode()})")
libpam.pam_end(handle, r)
