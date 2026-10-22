import tkinter as tk
import ctypes
import mss
import time
import sys

def run_test():
    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
    pt = POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
    print(f"Mouse Native: {pt.x}, {pt.y}")

    root = tk.Tk()
    root.withdraw()

    # Get logical pointer position
    logical_x = root.winfo_pointerx()
    logical_y = root.winfo_pointery()
    print(f"Mouse Logical: {logical_x}, {logical_y}")

    with mss.mss() as sct:
        target_mon = sct.monitors[1]
        for mon in sct.monitors[1:]:
            if (mon["left"] <= pt.x < mon["left"] + mon["width"] and
                mon["top"] <= pt.y < mon["top"] + mon["height"]):
                target_mon = mon
                break
        print(f"Native Monitor: Left {target_mon['left']}, Top {target_mon['top']}, W {target_mon['width']}, H {target_mon['height']}")

    w = tk.Toplevel(root)
    w.title("Test")
    # Move exactly to logical mouse, then fullscreen.
    w.geometry(f"+{logical_x}+{logical_y}")
    w.update_idletasks()
    
    # Try fullscreen
    w.attributes('-fullscreen', True)
    w.update_idletasks()

    print(f"Tk Logical geometry after FS: {w.winfo_width()}x{w.winfo_height()}+{w.winfo_rootx()}+{w.winfo_rooty()}")
    
    # Exit automatically after 3 seconds
    w.after(3000, root.destroy)
    root.mainloop()

if __name__ == '__main__':
    run_test()
