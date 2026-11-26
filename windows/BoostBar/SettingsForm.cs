using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace BoostBar
{
    /// BoostBar ▸ Settings… — every option, grouped in tabs (same tabs as the Mac version).
    class SettingsForm : Form
    {
        static SettingsForm shared;
        readonly TabControl tabs = new TabControl { Dock = DockStyle.Fill };
        readonly List<Action> refreshers = new List<Action>();
        readonly Dictionary<string, Action<Pane>> builders = new Dictionary<string, Action<Pane>>();
        readonly Dictionary<string, Pane> panes = new Dictionary<string, Pane>();
        bool loading;
        string saverScene = "cars";
        string diskKeys = "";

        public static void ShowShared(string tab)
        {
            if (shared == null || shared.IsDisposed) shared = new SettingsForm();
            if (tab != null) shared.Select(tab);
            shared.RefreshAll();
            shared.Show();
            if (shared.WindowState == FormWindowState.Minimized) shared.WindowState = FormWindowState.Normal;
            shared.Activate();
        }

        public static void RefreshOpen() { if (shared != null && !shared.IsDisposed && shared.Visible) shared.RefreshAll(); }

        public void Select(string tab)
        {
            foreach (TabPage p in tabs.TabPages) if (p.Text == tab) tabs.SelectedTab = p;
        }

        public SettingsForm(bool forSnapshot = false)
        {
            Text = "BoostBar Settings";
            Icon = App.AppIcon(32);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9f);
            ClientSize = new Size(750, 680);   // 25% wider than 1.3.74
            MinimumSize = new Size(640, 420);
            StartPosition = FormStartPosition.CenterScreen;
            Controls.Add(tabs);
            Add("General", BuildGeneral);
            Add("Sleep", BuildSleep);
            Add("Network", BuildNetwork);
            Add("Battery", BuildBattery);
            Add("CPU", BuildCpu);
            Add("Disks", BuildDisks);
            Add("Eyes", BuildEyes);
            Add("Screen Saver", BuildSaver);
            Add("Scrolling", BuildScrolling);
            RefreshAll();
        }

        void Add(string title, Action<Pane> build)
        {
            var page = new TabPage(title) { BackColor = SystemColors.Window, Padding = new Padding(0) };
            var pane = new Pane(this, page);
            builders[title] = build;
            panes[title] = pane;
            build(pane);
            tabs.TabPages.Add(page);
        }

        void Rebuild(string title)
        {
            var p = panes[title];
            p.Clear();
            builders[title](p);
            RefreshAll();
        }

        void RefreshAll()
        {
            var keys = string.Join(",", App.Shared?.Disk.Drives.Select(d => d.Key) ?? new string[0]);
            if (keys != diskKeys && panes.ContainsKey("Disks")) { diskKeys = keys; var p = panes["Disks"]; p.Clear(); BuildDisks(p); }
            loading = true;
            try { foreach (var p in panes.Values) foreach (var r in p.Refreshers) r(); }
            finally { loading = false; }
        }

        // ------------------------------------------------------------------ pane builder

        class Pane
        {
            readonly SettingsForm form;
            public readonly FlowLayoutPanel Flow;
            public readonly List<Action> Refreshers = new List<Action>();
            const int Width = 675;

            public Pane(SettingsForm f, TabPage page)
            {
                form = f;
                Flow = new FlowLayoutPanel
                {
                    Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true,
                    Padding = new Padding(18, 10, 18, 18), BackColor = SystemColors.Window,
                };
                page.Controls.Add(Flow);
            }

            public void Clear() { Flow.Controls.Clear(); Refreshers.Clear(); }
            bool Loading => form.loading;

            public void Header(string text)
            {
                Flow.Controls.Add(new Label
                {
                    Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 10.5f),
                    Margin = new Padding(0, Flow.Controls.Count == 0 ? 4 : 16, 0, 4),
                });
            }

            public void Note(string text, bool small = false)
            {
                Flow.Controls.Add(new Label
                {
                    Text = text, AutoSize = true, MaximumSize = new Size(Width, 0), ForeColor = SystemColors.GrayText,
                    Font = small ? new Font("Segoe UI", 8.5f) : null, Margin = new Padding(2, 2, 0, 6),
                });
            }

            public Label Dynamic(Func<string> text)
            {
                var l = new Label { AutoSize = true, MaximumSize = new Size(Width, 0), ForeColor = SystemColors.GrayText, Margin = new Padding(2, 2, 0, 6) };
                Flow.Controls.Add(l);
                Refreshers.Add(() => l.Text = text());
                return l;
            }

            public CheckBox Check(string text, Func<bool> get, Action<bool> set, bool indent = false, Func<bool> enabled = null)
            {
                var c = new CheckBox { Text = text, AutoSize = true, MaximumSize = new Size(Width, 0), Margin = new Padding(indent ? 22 : 2, 3, 0, 3) };
                c.CheckedChanged += (s, e) => { if (!Loading) { set(c.Checked); form.RefreshAll(); } };
                Flow.Controls.Add(c);
                Refreshers.Add(() => { c.Checked = get(); if (enabled != null) c.Enabled = enabled(); });
                return c;
            }

            Panel Row(string label, Control control, int labelWidth = 200)
            {
                var row = new Panel { Width = Width, Height = Math.Max(28, control.Height + 6), Margin = new Padding(0, 2, 0, 2) };
                var l = new Label { Text = label, AutoSize = false, Width = labelWidth, Height = row.Height, TextAlign = ContentAlignment.MiddleLeft, Left = 2 };
                control.Left = labelWidth + 6;
                control.Top = (row.Height - control.Height) / 2;
                row.Controls.Add(l); row.Controls.Add(control);
                Flow.Controls.Add(row);
                return row;
            }

            public ComboBox Popup(string label, string[] items, Func<int> get, Action<int> set)
            {
                var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320 };
                c.Items.AddRange(items);
                c.SelectedIndexChanged += (s, e) => { if (!Loading && c.SelectedIndex >= 0) { set(c.SelectedIndex); form.RefreshAll(); } };
                Row(label, c);
                Refreshers.Add(() => { var i = get(); if (i >= 0 && i < c.Items.Count) c.SelectedIndex = i; });
                return c;
            }

            /// A slider from `min` to `max` (optionally logarithmic), with a live value label.
            public void Slider(string label, double min, double max, Func<double> get, Action<double> set, Func<double, string> fmt, bool log = false)
            {
                var host = new Panel { Width = 420, Height = 32 };
                var t = new TrackBar { Minimum = 0, Maximum = 1000, TickStyle = TickStyle.None, Width = 320, Left = 0, Top = 0, AutoSize = false, Height = 30 };
                var v = new Label { AutoSize = false, Width = 90, Left = 326, Top = 6, Height = 20 };
                host.Controls.Add(t); host.Controls.Add(v);
                double ToVal(int p) => log ? Math.Exp(Math.Log(min) + (Math.Log(max) - Math.Log(min)) * p / 1000.0) : min + (max - min) * p / 1000.0;
                int ToPos(double x) => (int)Math.Round(Math.Max(0, Math.Min(1000, log ? (Math.Log(x) - Math.Log(min)) / (Math.Log(max) - Math.Log(min)) * 1000 : (x - min) / (max - min) * 1000)));
                t.ValueChanged += (s, e) => { v.Text = fmt(ToVal(t.Value)); if (!Loading) set(ToVal(t.Value)); };
                Row(label, host);
                Refreshers.Add(() => { t.Value = ToPos(get()); v.Text = fmt(get()); });
            }

            public Button Button(string text, Action act)
            {
                var b = new Button { Text = text, AutoSize = true, Margin = new Padding(2, 6, 0, 4), Padding = new Padding(8, 2, 8, 2) };
                b.Click += (s, e) => { act(); form.RefreshAll(); };
                Flow.Controls.Add(b);
                return b;
            }

            public void Buttons(params (string Text, Action Act)[] list)
            {
                var row = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(Width, 0), Margin = new Padding(0, 6, 0, 4) };
                foreach (var (text, act) in list)
                {
                    var b = new Button { Text = text, AutoSize = true, Padding = new Padding(8, 2, 8, 2), Margin = new Padding(2, 0, 6, 4) };
                    b.Click += (s, e) => { act(); form.RefreshAll(); };
                    row.Controls.Add(b);
                }
                Flow.Controls.Add(row);
            }

            public void Add(Control c) { Flow.Controls.Add(c); }

            /// Checkboxes in a grid (two columns by default), each with a tooltip; one refresher for all of them.
            public void CheckGrid((string Text, string Tip, Func<bool> Get, Action<bool> Set)[] items, int cols = 2, Func<bool> enabled = null, Action<int, bool> hover = null)
            {
                var grid = new TableLayoutPanel { ColumnCount = cols, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = new Padding(0, 2, 0, 4) };
                for (var c = 0; c < cols; c++) grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 300));
                var rows = (items.Length + cols - 1) / cols;
                var tips = new ToolTip();
                var boxes = new List<CheckBox>();
                for (var k = 0; k < items.Length; k++)
                {
                    var it = items[k];
                    var cb = new CheckBox { Text = it.Text, AutoSize = true, Margin = new Padding(2, 3, 0, 3) };
                    tips.SetToolTip(cb, it.Tip);
                    var index = k;
                    if (hover != null) { cb.MouseEnter += (s, e) => hover(index, true); cb.MouseLeave += (s, e) => hover(index, false); }
                    cb.CheckedChanged += (s, e) => { if (!Loading) { it.Set(cb.Checked); form.RefreshAll(); } };
                    grid.Controls.Add(cb, k / rows, k % rows);     // down the first column, then the second
                    boxes.Add(cb);
                }
                Flow.Controls.Add(grid);
                Refreshers.Add(() => { for (var k = 0; k < items.Length; k++) { boxes[k].Checked = items[k].Get(); if (enabled != null) boxes[k].Enabled = enabled(); } });
            }
        }

        static string[] ColorNames => Palette.Named.Select(n => n.Name).ToArray();
        static int ColorIndex(string name) { var i = Array.FindIndex(Palette.Named, n => n.Name == name); return i < 0 ? 0 : i; }
        static string[] CornerNames => HotCorners.Names.Select(n => n.Name).ToArray();

        // ------------------------------------------------------------------ tabs

        void BuildGeneral(Pane p)
        {
            p.Header("Startup");
            p.Check("Launch BoostBar when I sign in", () => LoginItem.IsEnabled, LoginItem.Set);
            p.Header("Placement");
            p.Popup("Show BoostBar", new[] { "On the taskbar", "As a floating bar" }, () => Prefs.Placement, i => Prefs.Placement = i);
            p.Note("On the taskbar it sits just left of the clock and tray icons. A floating bar can be dragged anywhere and stays on top (it hides over full-screen apps). Right-click either one for the menu.");
            p.Header("Updates");
            p.Check("Check for updates when BoostBar starts", () => Prefs.CheckOnLaunch, v => Prefs.CheckOnLaunch = v);
            p.Check("Install updates automatically", () => Prefs.AutoUpdate, v => Prefs.AutoUpdate = v);
            p.Note("A newer version found at startup is downloaded, checked against its published SHA-256 checksum, installed and relaunched — no prompt.");
            p.Header("Taskbar Layout");
            p.Check("Label the pieces with stacked text: NET, BAT, CPU, HDD", () => Prefs.VerticalLabels, v => Prefs.VerticalLabels = v);
            p.Note("Order of the pieces — the top of the list is leftmost. Select a row and use Up / Down, or drag a piece along the taskbar itself.");
            var list = new ListBox { Width = 320, Height = 110, Margin = new Padding(2, 2, 0, 2) };
            var names = new Dictionary<Segment, string> { { Segment.Eyes, "Googly eyes" }, { Segment.Network, "Network graph" }, { Segment.Battery, "Battery watts" }, { Segment.Cpu, "CPU meter" }, { Segment.Disks, "Disk lights" } };
            p.Add(list);
            p.Refreshers.Add(() =>
            {
                var sel = list.SelectedIndex;
                list.Items.Clear();
                foreach (var s in Prefs.SegmentOrder) list.Items.Add(names[s] + (App.Shared != null && !App.Shared.IsSegmentShown(s) ? "  (hidden)" : ""));
                if (sel >= 0 && sel < list.Items.Count) list.SelectedIndex = sel;
            });
            void Move(int d)
            {
                var i = list.SelectedIndex; var o = Prefs.SegmentOrder.ToList();
                if (i < 0 || i + d < 0 || i + d >= o.Count) return;
                var s = o[i]; o.RemoveAt(i); o.Insert(i + d, s);
                Prefs.SegmentOrder = o.ToArray();
                RefreshAll(); list.SelectedIndex = i + d;
            }
            p.Buttons(("Up", () => Move(-1)), ("Down", () => Move(1)), ("Reset Order", () => Prefs.SegmentOrder = Prefs.DefaultOrder));
            p.Header("Privacy");
            p.Check("Share anonymous install count", () => Prefs.ShareInstallCount, v => { Prefs.ShareInstallCount = v; if (v) InstallPing.SendIfNeeded(); });
            p.Note("Sends biz-cord.com a random ID, the BoostBar version, Windows version and CPU type, once per version. No personal info.");
            p.Header("About");
            p.Dynamic(() => "BoostBar " + Updater.CurrentVersion + " for Windows · by Mac McAlpine · MacsBoost");
            p.Buttons(("About BoostBar…", AboutForm.ShowShared), ("Check for Updates…", () => App.Shared?.Updater.Check(true)), ("GitHub", () => Shell.Open(Updater.RepoPage)));
        }

        void BuildSleep(Pane p)
        {
            var app = App.Shared;
            p.Header("Keep Awake");
            p.Check("Keep PC awake", () => app?.Sleep.IsPreventing ?? false, v => { if (v) app?.KeepAwakeFor(null); else app?.Sleep.Allow(); });
            p.Popup("Keep awake for", App.AwakeDurations.Select(d => d.Label).ToArray(), () => 0, i => app?.KeepAwakeFor(App.AwakeDurations[i].Minutes));
            p.Check("Keep the display on too", () => Prefs.KeepDisplayAwake, v => app?.SetKeepDisplayAwake(v));
            p.Note("Keep Awake is also in the BoostBar menu for one-click access. It ends when you turn it off, when the timer runs out, or when BoostBar quits.");
            p.Header("Lid Closed");
            if (LidSleep.Available)
            {
                p.Check("Stay awake with the lid closed", () => app?.LidDisabled ?? false, v => app?.ToggleLidSleep());
                p.Note("Sets the power plan's lid-close action to “Do nothing” (plugged in and on battery). Stays on after quitting or restarting until you turn it off; then your previous setting comes back. Don't bag a running laptop with this on.");
            }
            else p.Note("This PC has no lid (no battery found), so there's nothing to change here.");
            p.Header("Hot Corners");
            p.Popup("Toggle Keep Awake", CornerNames, () => (int)Prefs.CornerAwake, i => Prefs.CornerAwake = (Corner)i);
            p.Popup("Sleep now", CornerNames, () => (int)Prefs.CornerSleep, i => Prefs.CornerSleep = (Corner)i);
            p.Note("Rest the pointer in the corner for a moment. A small badge confirms the action.");
        }

        void BuildNetwork(Pane p)
        {
            p.Header("Taskbar");
            p.Check("Show network speed graph", () => Prefs.ShowNetwork, v => Prefs.ShowNetwork = v);
            p.Popup("Smallest unit", new[] { "KB/s and up", "MB/s and up" }, () => Prefs.NetUnit == Fmt.NetUnit.Mega ? 1 : 0, i => Prefs.NetUnit = i == 1 ? Fmt.NetUnit.Mega : Fmt.NetUnit.Auto);
            p.Check("Show bits per second (Kb/s, Mb/s) instead of bytes", () => Prefs.UseBits, v => Prefs.UseBits = v);
            p.Popup("Graphs", new[] { "One per connection", "One combined graph" }, () => Prefs.NetSplit ? 0 : 1, i => Prefs.NetSplit = i == 0);
            p.Dynamic(() => App.Shared?.NetworkSummary() ?? "");
            p.Note("Hover over the graph for a 5-minute chart.");
            p.Header("Trace Colors");
            p.Popup("Preset", Palette.TracePresets.Select(t => t.Name).ToArray(),
                () => Array.FindIndex(Palette.TracePresets, t => t.Up == Prefs.UpColorName && t.Down == Prefs.DownColorName),
                i => { Prefs.UpColorName = Palette.TracePresets[i].Up; Prefs.DownColorName = Palette.TracePresets[i].Down; });
            p.Popup("Upload", ColorNames, () => ColorIndex(Prefs.UpColorName), i => Prefs.UpColorName = Palette.Named[i].Name);
            p.Popup("Download", ColorNames, () => ColorIndex(Prefs.DownColorName), i => Prefs.DownColorName = Palette.Named[i].Name);
        }

        void BuildBattery(Pane p)
        {
            p.Header("Taskbar");
            if (BatteryMonitor.HasBattery)
            {
                p.Check("Show battery power (watts in / out)", () => Prefs.ShowBattery, v => Prefs.ShowBattery = v);
                p.Note("Green IN = charging, orange OUT = running on battery. Hover for time to full / empty, cycle count, battery health and a 10-minute power chart.");
            }
            else p.Note("No battery found on this PC, so the battery readout is hidden.");
        }

        void BuildCpu(Pane p)
        {
            p.Header("Taskbar");
            p.Check("Show CPU meter", () => Prefs.ShowCPU, v => Prefs.ShowCPU = v);
            p.Popup("Style", new[] { "Boost gauge (half-round, with a needle)", "Spectrum analyzer (a bar per core)" }, () => Prefs.CpuStyle, i => Prefs.CpuStyle = i);
            p.Slider("Update rate", 1, 60, () => Prefs.CpuRate, v => Prefs.CpuRate = v, v => v.ToString("0") + " Hz", log: true);
            p.Slider("Backdrop", -1, 1, () => Prefs.CpuBackdrop, v => Prefs.CpuBackdrop = v,
                v => Math.Abs(v) < 0.04 ? "Off" : (v < 0 ? "Dark " : "Light ") + (Math.Abs(v) * 100).ToString("0") + "%");
            p.Slider("Peak hold", 0, 10, () => Prefs.CpuPeakHold, v => Prefs.CpuPeakHold = v, v => v < 0.2 ? "Off" : v.ToString("0.0") + " s");
            p.Note("Damping is automatic: the needle and bars glide between readings, with a longer sweep at slow rates and a quicker one at fast rates. At 20 Hz and above the meter also redraws that often (up to 60 frames a second), which uses a little more power.");
            p.Note("The meter is green at idle, through yellow and orange, to red at full load. Hover it for a 5-minute chart. Move it in General ▸ Taskbar Layout.");
        }

        void BuildDisks(Pane p)
        {
            p.Header("Disk Activity Lights");
            p.Check("Show disk lights on the taskbar", () => Prefs.ShowDisks, v => Prefs.ShowDisks = v);
            p.Popup("LED size", Prefs.SizeNames, () => Prefs.LedSize, i => Prefs.LedSize = i);
            p.Popup("Blink duration", Prefs.LedDurations.Select(d => d + " ms").ToArray(), () => Math.Max(0, Array.IndexOf(Prefs.LedDurations, Prefs.LedDurationMs)), i => Prefs.LedDurationMs = Prefs.LedDurations[i]);
            p.Header("Drives");
            var drives = App.Shared?.Disk.Drives ?? new List<DiskMonitor.Drive>();
            if (drives.Count == 0) p.Note("No drives found yet.");
            foreach (var d in drives)
            {
                var key = d.Key; var isInternal = d.IsInternal;
                var row = new Panel { Width = 675, Height = 30, Margin = new Padding(0, 1, 0, 1) };
                var c = new CheckBox { Text = d.Name + "  ·  " + d.Kind + "  ·  " + Fmt.Bytes(d.Size), AutoSize = false, Width = 470, Height = 26, Left = 2, Top = 2 };
                var col = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 180, Left = 480, Top = 3 };
                col.Items.AddRange(ColorNames);
                c.CheckedChanged += (s, e) => { if (!loading) Prefs.SetDiskEnabled(key, c.Checked); };
                col.SelectedIndexChanged += (s, e) => { if (!loading && col.SelectedIndex >= 0) Prefs.SetDiskColorName(key, Palette.Named[col.SelectedIndex].Name); };
                row.Controls.Add(c); row.Controls.Add(col);
                p.Add(row);
                p.Refreshers.Add(() => { c.Checked = Prefs.DiskEnabled(key); col.SelectedIndex = ColorIndex(Prefs.DiskColorName(key, isInternal)); });
            }
            p.Note("USB flash drives and SD cards appear here when plugged in. Hover a light for volumes, free space and read/write speed.");
        }

        void BuildEyes(Pane p)
        {
            p.Header("Googly Eyes");
            p.Check("Show googly eyes that follow the mouse", () => Prefs.ShowEyes, v => Prefs.ShowEyes = v);
            p.Popup("Size", Prefs.SizeNames, () => Prefs.EyeSize, i => Prefs.EyeSize = i);
            p.Check("Single eye (cyclops)", () => Prefs.SingleEye, v => Prefs.SingleEye = v);
            p.Header("Behavior");
            p.Check("Googly wobble", () => Prefs.Googly, v => Prefs.Googly = v);
            p.Check("Blink now and then", () => Prefs.EyeBlink, v => Prefs.EyeBlink = v);
            p.Check("Allow cross-eyed (each eye follows the pointer on its own)", () => Prefs.AllowCrossEye, v => Prefs.AllowCrossEye = v);
            p.Check("Lazy (they take their time following the pointer)", () => Prefs.LazyEyes, v => Prefs.LazyEyes = v);
            p.Header("Looks");
            p.Check("Bloodshot", () => Prefs.Bloodshot, v => Prefs.Bloodshot = v);
            p.Check("Bloodshot while keeping the PC awake", () => Prefs.BloodshotAwake, v => Prefs.BloodshotAwake = v);
            p.Check("Pirate eyepatch", () => Prefs.Pirate, v => Prefs.Pirate = v);
            p.Popup("Lashes", new[] { "None", "Natural", "Fake" }, () => Prefs.Lashes, i => Prefs.Lashes = i);
            p.Header("Emotions");
            p.CheckGrid(Emotions.All.Select(e => (Emotions.Title(e), Emotions.When(e),
                (Func<bool>)(() => !Prefs.EmotionsOff.Contains(e)),
                (Action<bool>)(v => { var off = Prefs.EmotionsOff; if (v) off.Remove(e); else off.Add(e); Prefs.EmotionsOff = off; }))).ToArray(),
                enabled: () => Prefs.ShowEyes, hover: (i, on) => App.Shared?.PreviewEmotion(Emotions.All[i], on));   // hover a name to see the eyes do it
            p.Note("Sleepy when idle, alarmed or angry when the CPU is slammed, sweating after a minute flat out, happy on the charger, sad with no network, suspicious of a lingering pointer, a one-eye skeptical squint when you whip the pointer around, startled by a new drive, bored now and then — and hearts for a tip. Hover over a name to see the eyes do it (and when it shows).", small: true);
            p.Note("Click the eyes to open the About window. Circle the pointer over them two and a half times to spin them. A tribute to the classic desktop toys that kept an eye on your cursor.", small: true);
        }

        void BuildSaver(Pane p)
        {
            var scene = saverScene;
            var o = SaverConfig.Load(scene);
            void Change(Action<SaverOptions> f) { var x = SaverConfig.Load(scene); f(x); SaverConfig.Save(scene, x); }
            p.Header("Screen Saver");
            p.Popup("Screen saver", SaverConfig.Scenes.Select(SaverConfig.Title).ToArray(), () => Array.IndexOf(SaverConfig.Scenes, saverScene),
                i => { saverScene = SaverConfig.Scenes[i]; BeginInvoke((Action)(() => Rebuild("Screen Saver"))); });
            p.Note(ScreenSavers.Blurb(scene));
            p.Dynamic(() => ScreenSavers.Status(scene));
            p.Buttons(("Preview", () => ScreenSavers.Preview(scene)), ("Use as My Screen Saver", () => ScreenSavers.Use(scene)),
                      ("Start Now", () => ScreenSavers.Run(scene)), ("Screen Saver Settings…", ScreenSavers.OpenWindowsSettings));
            p.Popup("Hot corner", CornerNames, () => (int)Prefs.CornerSaver, i => Prefs.CornerSaver = (Corner)i);
            p.Note("Rest the pointer there to start your screen saver. Pick a corner Keep Awake and Sleep now don't use.");
            if (scene == "jetrace")
            {
                void Choice(string label, (string Id, string Name)[] list, Func<SaverOptions, string> get, Action<SaverOptions, string> set) =>
                    p.Popup(label, list.Select(x => x.Name).ToArray(), () => JetRace.Index(list, get(SaverConfig.Load(scene))), i => Change(x => set(x, list[i].Id)));
                p.Header("Race");
                Choice("Winner", JetRace.Winners, x => x.Winner, (x, v) => x.Winner = v);
                p.Note("Random runs a fair race: any of the three can win. Pick a racer and every race is one that racer wins.", small: true);
                Choice("Winner celebration", JetRace.Celebrations, x => x.Celebration, (x, v) => x.Celebration = v);
                p.Note("After the finish the winner spins out, then celebrates. Random picks a different celebration each race.", small: true);
                p.Header("Coverage");
                Choice("Camera", JetRace.Cameras, x => x.Camera, (x, v) => x.Camera = v);
                Choice("Follow", JetRace.Follows, x => x.Follow, (x, v) => x.Follow = v);
                p.Check("Leaderboard", () => SaverConfig.Load(scene).Board, v => Change(x => x.Board = v));
                p.Check("Camera captions", () => SaverConfig.Load(scene).Captions, v => Change(x => x.Captions = v));
                p.Note("Changes apply the next time the screen saver starts, and in Preview.", small: true);
                return;
            }
            p.Header("Flight");
            p.Slider("How many", 1, scene == "starlink" ? 69 : 20, () => SaverConfig.Load(scene).Count, v => Change(x => x.Count = (int)Math.Round(v)), v => Math.Round(v).ToString("0"));
            p.Slider("Speed", 0.25, 3, () => SaverConfig.Load(scene).Speed, v => Change(x => x.Speed = Math.Round(v, 2)), v => v.ToString("0.00") + "×");
            p.Slider("Flap speed", 0.25, 3, () => SaverConfig.Load(scene).FlapSpeed, v => Change(x => x.FlapSpeed = Math.Round(v, 2)), v => v.ToString("0.00") + "×");
            p.Slider("Roll angle", -90, 90, () => SaverConfig.Load(scene).Tilt ?? SaverConfig.DefaultTilt(scene), v => Change(x => x.Tilt = Math.Round(v)), v => v.ToString("0") + "°");
            p.Slider("Flock angle", 0, 360, () => SaverConfig.Load(scene).Heading ?? SaverConfig.DefaultHeading, v => Change(x => x.Heading = Math.Round(v)), SaverConfig.HeadingText);
            p.Buttons(("Default Angles", () => Change(x => { x.Tilt = null; x.Heading = null; })));
            p.Note("Roll angle: how far each craft is rolled toward you. Flock angle: the direction they fly across the screen.", small: true);
            p.Check("Stunts (barrel rolls, veers, climbs and dives)", () => SaverConfig.Load(scene).Stunts, v => Change(x => x.Stunts = v));
            p.Header("Scene");
            var choices = ScreenSavers.Choices(scene);
            foreach (var (id, name) in choices)
                p.Check(name, () => SaverConfig.Load(scene).Liveries.Contains(id), v => Change(x =>
                {
                    x.Liveries.Remove(id);
                    if (v) x.Liveries.Add(id);
                    if (x.Liveries.Count == 0) x.Liveries.Add(id);   // keep at least one
                }));
            if (scene == "starships")
            {
                p.Slider("Oxidation", 0, 1, () => SaverConfig.Load(scene).Oxidation, v => Change(x => x.Oxidation = Math.Round(v, 2)), v => (v * 100).ToString("0") + "%");
                p.Check("Roadster with Starman", () => SaverConfig.Load(scene).Roadster, v => Change(x => x.Roadster = v));
                p.Check("Stabilized (flies level with the ships instead of tumbling)", () => SaverConfig.Load(scene).RoadsterStable, v => Change(x => x.RoadsterStable = v), indent: true,
                        enabled: () => SaverConfig.Load(scene).Roadster);
                p.Check("Close encounter (now and then a ship flaps by right in front of you)", () => SaverConfig.Load(scene).CloseEncounter, v => Change(x => x.CloseEncounter = v));
            }
            if (scene == "starlink")
            {
                p.Check("Crossing orbits (strings of satellites in an X pattern)", () => SaverConfig.Load(scene).Crossing, v => Change(x => x.Crossing = v));
                p.Check("Laser links between nearby satellites", () => SaverConfig.Load(scene).Lasers, v => Change(x => x.Lasers = v));
            }
            if (scene == "cars") p.Check("Clouds (a blue daytime sky)", () => SaverConfig.Load(scene).Clouds, v => Change(x => x.Clouds = v));
            p.Check("Stars in the background", () => SaverConfig.Load(scene).Stars, v => Change(x => x.Stars = v));
            p.Note("Changes apply the next time the screen saver starts, and in Preview. Not affiliated with SpaceX; the X1 SkyRacer, its liveries and the Starship come from the X1 SkyRacer Flying Car Race Sim.", small: true);
        }

        void BuildScrolling(Pane p)
        {
            p.Header("Mouse Scrolling");
            p.Check("Reverse mouse scrolling", () => Prefs.ReverseScroll, v => Prefs.ReverseScroll = v);
            p.Check("Include horizontal scrolling (tilt wheel)", () => Prefs.ReverseHorizontal, v => Prefs.ReverseHorizontal = v, indent: true);
            p.Note("Flips the wheel direction in every app, with no special permission. Windows doesn't let apps reach into windows running as administrator, so scrolling there keeps its normal direction.");
            p.Note("Touchpads have their own direction setting in Windows Settings ▸ Bluetooth & devices ▸ Touchpad ▸ Scroll & zoom. If your touchpad flips along with the mouse, set its direction there.");
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
            base.OnFormClosing(e);
        }

        /// Renders every tab to PNGs (run with --snapshot; used to check the layout in CI).
        public void Snapshot(string dir)
        {
            Show();
            foreach (TabPage page in tabs.TabPages)
            {
                var scenes = page.Text == "Screen Saver" ? SaverConfig.Scenes : new[] { "" };
                foreach (var s in scenes)
                {
                    if (s != "") { saverScene = s; Rebuild("Screen Saver"); }
                    tabs.SelectedTab = page;
                    Application.DoEvents();
                    var flow = (FlowLayoutPanel)page.Controls[0];
                    var h = Math.Max(ClientSize.Height, flow.DisplayRectangle.Height + 60);
                    var old = ClientSize;
                    ClientSize = new Size(old.Width, Math.Min(h, 1400));
                    Application.DoEvents();
                    using (var bmp = new Bitmap(Width, Height))
                    {
                        DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                        bmp.Save(System.IO.Path.Combine(dir, "settings_" + page.Text.Replace(" ", "") + (s != "" ? "_" + s : "") + ".png"));
                    }
                    ClientSize = old;
                }
            }
            Hide();
        }
    }
}
