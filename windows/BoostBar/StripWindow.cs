using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BoostBar
{
    /// The see-through window that shows the strip. On the taskbar it is a child of the taskbar window, placed just
    /// left of the notification area (on Windows 10 the task buttons are narrowed to make room), so it moves, hides
    /// and auto-hides with the taskbar. If the taskbar can't be found, or is on the left/right edge, it floats.
    class StripWindow : NativeWindow, IDisposable
    {
        public event Action<Point> MouseMoved;      // client pixels
        public event Action MouseLeft;
        public event Action<Point> LeftDown, LeftUp, RightUp;
        public event Action LayoutChanged;          // taskbar moved, DPI changed, explorer restarted…

        public bool Embedded { get; private set; }
        public bool WantFloating;
        public int HeightPx { get; private set; } = 40;
        public float Zoom { get; private set; } = 1.4f;
        public bool TaskbarOnTop { get; private set; }
        public Rectangle ScreenBounds { get; private set; }

        IntPtr taskbar, rebar;
        int rebarOriginalRight = -1;
        int widthPx = 10;
        Point floatPos;
        bool tracking;
        readonly Timer watch = new Timer { Interval = 1000 };

        const int WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202, WM_RBUTTONUP = 0x205, WM_MOUSELEAVE = 0x2A3,
                  WM_NCHITTEST = 0x84, HTCLIENT = 1, WM_DPICHANGED = 0x02E0;

        [StructLayout(LayoutKind.Sequential)] struct TRACKMOUSEEVENT { public int cbSize; public uint dwFlags; public IntPtr hwndTrack; public uint dwHoverTime; }
        [DllImport("user32.dll")] static extern bool TrackMouseEvent(ref TRACKMOUSEEVENT t);
        [DllImport("user32.dll")] static extern IntPtr SetCapture(IntPtr h);
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        public void Capture(bool on) { if (on) SetCapture(Handle); else ReleaseCapture(); }

        public StripWindow(bool floating)
        {
            WantFloating = floating;
            watch.Tick += (s, e) => Reposition(false);
        }

        public void Start()
        {
            Attach();
            watch.Start();
        }

        CreateParams Params(bool child)
        {
            var cp = new CreateParams { Caption = "BoostBar", X = 0, Y = 0, Width = widthPx, Height = HeightPx };
            if (child)
            {
                cp.Parent = taskbar;
                cp.Style = Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_CLIPSIBLINGS;
                cp.ExStyle = Native.WS_EX_LAYERED | Native.WS_EX_NOACTIVATE;
            }
            else
            {
                cp.Style = Native.WS_POPUP | Native.WS_VISIBLE;
                cp.ExStyle = Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
            }
            return cp;
        }

        /// (Re)creates the window on the taskbar, or floating.
        void Attach()
        {
            RestoreRebar();
            if (Handle != IntPtr.Zero) DestroyHandle();
            taskbar = Native.FindWindow("Shell_TrayWnd", null);
            var horizontal = false;
            if (taskbar != IntPtr.Zero && Native.GetWindowRect(taskbar, out var tr)) horizontal = tr.Width > tr.Height;
            Embedded = !WantFloating && taskbar != IntPtr.Zero && horizontal;
            Measure();
            try { CreateHandle(Params(Embedded)); }
            catch { Embedded = false; CreateHandle(Params(false)); }
            if (Embedded && Native.GetParent(Handle) != taskbar)
            {
                // creating straight into the taskbar failed on this build: fall back to SetParent
                Native.SetParent(Handle, taskbar);
                Native.SetWindowLong(Handle, Native.GWL_STYLE, Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_CLIPSIBLINGS);
            }
            if (!Embedded)
            {
                var wa = Screen.PrimaryScreen.WorkingArea;
                floatPos = Prefs.FloatX != int.MinValue && Prefs.FloatY != int.MinValue
                    ? new Point(Prefs.FloatX, Prefs.FloatY)
                    : new Point(wa.Right - 420, wa.Bottom - HeightPx - 12);
                floatPos = ClampToScreens(floatPos);
            }
            Reposition(true);
            LayoutChanged?.Invoke();
        }

        Point ClampToScreens(Point p)
        {
            foreach (var s in Screen.AllScreens)
                if (s.WorkingArea.Contains(p)) return p;
            var wa = Screen.PrimaryScreen.WorkingArea;
            return new Point(wa.Right - 420, wa.Bottom - HeightPx - 12);
        }

        /// Height and zoom from the taskbar (or the primary screen's DPI when floating).
        void Measure()
        {
            uint dpi = 96;
            try { dpi = taskbar != IntPtr.Zero ? Native.GetDpiForWindow(taskbar) : 96; } catch { }
            if (dpi == 0) dpi = 96;
            var scale = dpi / 96f;
            Zoom = scale * 1.4f;
            if (Embedded && Native.GetWindowRect(taskbar, out var r)) HeightPx = r.Height;
            else HeightPx = (int)Math.Round(StripRenderer.BandHeight * Zoom + 6 * scale);
            if (HeightPx < 20) HeightPx = (int)Math.Round(30 * scale);
        }

        public void SetFloating(bool floating)
        {
            if (WantFloating == floating && Embedded == !floating) return;
            WantFloating = floating;
            Attach();
        }

        /// Keeps the window where it belongs; call with force after a size change.
        void Reposition(bool force)
        {
            if (Handle == IntPtr.Zero) return;
            if (Embedded)
            {
                if (!Native.IsWindow(taskbar) || Native.FindWindow("Shell_TrayWnd", null) != taskbar) { Attach(); return; }   // explorer restarted
                if (!Native.GetWindowRect(taskbar, out var tb)) return;
                if (tb.Width <= tb.Height) { Attach(); return; }   // moved to a side edge
                var oldH = HeightPx; var oldZ = Zoom;
                Measure();
                if (oldH != HeightPx || Math.Abs(oldZ - Zoom) > 0.01f) { LayoutChanged?.Invoke(); return; }
                TaskbarOnTop = tb.Top <= Screen.FromHandle(taskbar).Bounds.Top + 2 && tb.Height < Screen.FromHandle(taskbar).Bounds.Height / 2;
                var tray = Native.FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
                int right;
                if (tray != IntPtr.Zero && Native.GetWindowRect(tray, out var trr) && trr.Width > 0) right = trr.Left - tb.Left - 2;
                else right = tb.Width - (int)(260 * Zoom / 1.4f);
                if (!Theme.IsWindows11) right = SqueezeRebar(tb, right);
                var x = right - widthPx;
                Native.SetWindowPos(Handle, Native.HWND_TOP, x, 0, widthPx, HeightPx, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
                ScreenBounds = new Rectangle(tb.Left + x, tb.Top, widthPx, HeightPx);
            }
            else
            {
                // hide over full-screen apps and presentations
                var busy = Native.SHQueryUserNotificationState(out var st) == 0 && (st == 2 || st == 3 || st == 4);
                Native.SetWindowPos(Handle, Native.HWND_TOPMOST, floatPos.X, floatPos.Y, widthPx, HeightPx,
                    Native.SWP_NOACTIVATE | (busy ? 0x80u /* SWP_HIDEWINDOW */ : Native.SWP_SHOWWINDOW));
                ScreenBounds = new Rectangle(floatPos.X, floatPos.Y, widthPx, HeightPx);
                TaskbarOnTop = false;
            }
        }

        /// Windows 10: narrow the task-button area so the strip sits between it and the tray. Returns the strip's right edge.
        int SqueezeRebar(Native.RECT tb, int right)
        {
            rebar = Native.FindWindowEx(taskbar, IntPtr.Zero, "ReBarWindow32", null);
            if (rebar == IntPtr.Zero || !Native.GetWindowRect(rebar, out var rr)) return right;
            var left = rr.Left - tb.Left;
            if (rebarOriginalRight < 0) rebarOriginalRight = rr.Right - tb.Left;
            var want = right - widthPx - 2 - left;
            if (want > 50 && Math.Abs(rr.Width - want) > 1)
                Native.MoveWindow(rebar, left, rr.Top - tb.Top, want, rr.Height, true);
            return right;
        }

        void RestoreRebar()
        {
            if (rebar != IntPtr.Zero && rebarOriginalRight > 0 && Native.IsWindow(rebar) && Native.IsWindow(taskbar)
                && Native.GetWindowRect(rebar, out var rr) && Native.GetWindowRect(taskbar, out var tb))
            {
                var tray = Native.FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
                var right = tray != IntPtr.Zero && Native.GetWindowRect(tray, out var t) ? t.Left - tb.Left : rebarOriginalRight;
                Native.MoveWindow(rebar, rr.Left - tb.Left, rr.Top - tb.Top, right - (rr.Left - tb.Left), rr.Height, true);
            }
            rebar = IntPtr.Zero;
            rebarOriginalRight = -1;
        }

        // Reused between frames so a 60 Hz redraw doesn't allocate: a GDI+ back buffer and a DIB section of the same
        // size, selected into a memory DC. Each frame draws into the back buffer, copies its pixels into the DIB and
        // hands that to UpdateLayeredWindow.
        Bitmap back;
        IntPtr memDC, dib, dibBits, oldObj;

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

        void EnsureBuffers(int w, int h)
        {
            if (back != null && back.Width == w && back.Height == h) return;
            FreeBuffers();
            back = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
            memDC = Native.CreateCompatibleDC(IntPtr.Zero);
            var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER)), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
            dib = CreateDIBSection(memDC, ref bmi, 0, out dibBits, IntPtr.Zero, 0);
            oldObj = Native.SelectObject(memDC, dib);
        }

        void FreeBuffers()
        {
            if (memDC != IntPtr.Zero) { Native.SelectObject(memDC, oldObj); Native.DeleteDC(memDC); memDC = IntPtr.Zero; }
            if (dib != IntPtr.Zero) { Native.DeleteObject(dib); dib = IntPtr.Zero; }
            back?.Dispose(); back = null;
        }

        /// Draws the strip into the window (per-pixel alpha).
        public void Render(StripRenderer r, float widthUnits)
        {
            if (Handle == IntPtr.Zero) return;
            var w = Math.Max(4, (int)Math.Ceiling(widthUnits * Zoom));
            var sizeChanged = w != widthPx;
            widthPx = w;
            EnsureBuffers(w, HeightPx);
            using (var g = Graphics.FromImage(back)) Paint(g, r, Zoom, w, HeightPx);
            Blit();
            if (sizeChanged) Reposition(true);
        }

        static void Paint(Graphics g, StripRenderer r, float zoom, int w, int h)
        {
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            g.Clear(Color.FromArgb(1, 0, 0, 0));   // alpha 1: invisible, but still takes the mouse
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver;
            g.ScaleTransform(zoom, zoom);
            g.TranslateTransform(0, (h / zoom - StripRenderer.BandHeight) / 2);
            r.Draw(g);
        }

        public static Bitmap RenderBitmap(StripRenderer r, float zoom, int w, int h)
        {
            var bmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(bmp)) Paint(g, r, zoom, w, h);
            return bmp;
        }

        unsafe void Blit()
        {
            if (dibBits == IntPtr.Zero) return;
            var rect = new Rectangle(0, 0, back.Width, back.Height);
            var data = back.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
            try
            {
                var rowBytes = back.Width * 4;
                for (var y = 0; y < back.Height; y++)
                    Buffer.MemoryCopy((byte*)data.Scan0 + (long)y * data.Stride, (byte*)dibBits + (long)y * rowBytes, rowBytes, rowBytes);
            }
            finally { back.UnlockBits(data); }
            var size = new Native.SIZE(back.Width, back.Height);
            var src = new Native.POINT(0, 0);
            var blend = new Native.BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            if (Embedded) Native.UpdateLayeredWindow(Handle, IntPtr.Zero, IntPtr.Zero, ref size, memDC, ref src, 0, ref blend, Native.ULW_ALPHA);
            else
            {
                var dst = new Native.POINT(floatPos.X, floatPos.Y);
                Native.UpdateLayeredWindow(Handle, IntPtr.Zero, ref dst, ref size, memDC, ref src, 0, ref blend, Native.ULW_ALPHA);
            }
        }

        /// Floating mode: move the bar by dragging it.
        public void MoveFloatingBy(int dx, int dy)
        {
            if (Embedded) return;
            floatPos = new Point(floatPos.X + dx, floatPos.Y + dy);
            Reposition(true);
        }

        public void SaveFloatingPosition() { if (!Embedded) { Prefs.FloatX = floatPos.X; Prefs.FloatY = floatPos.Y; } }

        static Point Pt(IntPtr l) => new Point((short)(l.ToInt64() & 0xFFFF), (short)((l.ToInt64() >> 16) & 0xFFFF));

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case Native.WM_MOUSEACTIVATE: m.Result = new IntPtr(Native.MA_NOACTIVATE); return;
                case WM_NCHITTEST: m.Result = new IntPtr(HTCLIENT); return;
                case WM_MOUSEMOVE:
                    if (!tracking)
                    {
                        var t = new TRACKMOUSEEVENT { cbSize = Marshal.SizeOf(typeof(TRACKMOUSEEVENT)), dwFlags = 2 /* TME_LEAVE */, hwndTrack = Handle };
                        tracking = TrackMouseEvent(ref t);
                    }
                    MouseMoved?.Invoke(Pt(m.LParam));
                    break;
                case WM_MOUSELEAVE: tracking = false; MouseLeft?.Invoke(); break;
                case WM_LBUTTONDOWN: LeftDown?.Invoke(Pt(m.LParam)); break;
                case WM_LBUTTONUP: LeftUp?.Invoke(Pt(m.LParam)); break;
                case WM_RBUTTONUP: RightUp?.Invoke(Pt(m.LParam)); return;
                case WM_DPICHANGED: LayoutChanged?.Invoke(); break;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            watch.Stop();
            RestoreRebar();
            if (Handle != IntPtr.Zero) DestroyHandle();
            FreeBuffers();
        }
    }
}
