import dbus, os, sys, struct
from PIL import Image
handle = sys.argv[1]; out = sys.argv[2]
bus = dbus.SessionBus()
ss = bus.get_object("org.kde.KWin.ScreenShot2", "/org/kde/KWin/ScreenShot2")
r, w = os.pipe()
iface = dbus.Interface(ss, "org.kde.KWin.ScreenShot2")
res = iface.CaptureWindow(handle, {"include-decoration": dbus.Boolean(True)}, dbus.types.UnixFd(w))
os.close(w)
width, height, stride, fmt = int(res["width"]), int(res["height"]), int(res["stride"]), int(res["format"])
data = b""
with os.fdopen(r, "rb") as f:
    data = f.read()
im = Image.frombytes("RGBA", (width, height), data, "raw", "BGRA", stride)
im.save(out); print(width, height, "fmt", fmt)
