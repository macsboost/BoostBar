using System;
using System.Threading;

namespace BoostBar
{
    /// Flips the mouse wheel in every app with a low-level mouse hook: each wheel notch is swallowed and sent
    /// again with the opposite sign. Runs on its own thread so a busy UI never makes Windows drop the hook.
    /// No permission is needed. (Precision touchpads have their own direction setting in Windows Settings.)
    class ScrollReverser
    {
        static readonly IntPtr Marker = new IntPtr(0x42425253);   // "BBRS": our own re-sent events
        Thread thread;
        uint threadId;
        IntPtr hook;
        Native.LowLevelProc proc;   // kept alive so the GC doesn't collect the callback
        public volatile bool ReverseHorizontal;
        public bool IsRunning => thread != null;

        public void Start()
        {
            if (thread != null) return;
            var ready = new ManualResetEventSlim();
            thread = new Thread(() =>
            {
                threadId = Native.GetCurrentThreadId();
                proc = Callback;
                hook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, proc, Native.GetModuleHandle(null), 0);
                ready.Set();
                while (Native.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
                {
                    Native.TranslateMessage(ref msg);
                    Native.DispatchMessage(ref msg);
                }
                if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
                hook = IntPtr.Zero;
            }) { IsBackground = true, Name = "BoostBar scroll hook", Priority = ThreadPriority.AboveNormal };
            thread.Start();
            ready.Wait(2000);
        }

        public void Stop()
        {
            if (thread == null) return;
            Native.PostThreadMessage(threadId, Native.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            thread.Join(1000);
            thread = null;
        }

        IntPtr Callback(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0)
            {
                var m = w.ToInt32();
                if (m == Native.WM_MOUSEWHEEL || (m == Native.WM_MOUSEHWHEEL && ReverseHorizontal))
                {
                    var info = (Native.MSLLHOOKSTRUCT)System.Runtime.InteropServices.Marshal.PtrToStructure(l, typeof(Native.MSLLHOOKSTRUCT));
                    if (info.dwExtraInfo != Marker)
                    {
                        var delta = (short)((info.mouseData >> 16) & 0xFFFF);
                        if (delta != 0)
                        {
                            var input = new Native.INPUT
                            {
                                type = Native.INPUT_MOUSE,
                                u = new Native.InputUnion
                                {
                                    mi = new Native.MOUSEINPUT
                                    {
                                        mouseData = unchecked((uint)(-delta)),
                                        dwFlags = m == Native.WM_MOUSEWHEEL ? Native.MOUSEEVENTF_WHEEL : Native.MOUSEEVENTF_HWHEEL,
                                        dwExtraInfo = Marker,
                                    },
                                },
                            };
                            if (Native.SendInput(1, new[] { input }, System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.INPUT))) == 1)
                                return new IntPtr(1);   // swallow the original
                        }
                    }
                }
            }
            return Native.CallNextHookEx(hook, code, w, l);
        }
    }
}
