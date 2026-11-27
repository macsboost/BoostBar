using System;
using System.Drawing;
using System.Windows.Forms;

namespace BoostBar
{
    /// "About BoostBar" + the energydrinkware tip page.
    class AboutForm : Form
    {
        static AboutForm shared;
        const string Amount = "4.95", PayEmail = "mac@supermac.net", VenmoUser = "john-mcalpine-16", StripeUrl = "https://biz-cord.com/boostbar/donate";
        static readonly (string Title, string Url)[] Sites =
        {
            ("macsboost.com", "https://macsboost.com"), ("ssi-d.com", "https://ssi-d.com"), ("x1racing.com", "https://x1racing.com"),
            ("buildflyingcars.com", "https://buildflyingcars.com"), ("biz-cord.com", "https://biz-cord.com"),
        };
        static readonly (string Title, string Url)[] Socials = { ("@realx1racing", "https://x.com/realx1racing"), ("@macsboost", "https://x.com/macsboost"), ("@solarsi_d", "https://x.com/solarsi_d") };

        public static void ShowIfFirstLaunch()
        {
            if (Prefs.GetBool("supportShownOnce", false)) return;
            Prefs.SetBool("supportShownOnce", true);
            var t = new Timer { Interval = 1500 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); ShowShared(); };
            t.Start();
        }

        public static void ShowShared()
        {
            if (shared == null || shared.IsDisposed) shared = new AboutForm();
            shared.Show();
            shared.Activate();
        }

        static string Esc(string s) => Uri.EscapeDataString(s);

        public AboutForm()
        {
            Text = "About BoostBar";
            Icon = App.AppIcon(32);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9.5f);
            BackColor = Color.FromArgb(18, 19, 18);
            ForeColor = Color.White;
            // As on the Mac: the window is exactly as wide as the MACSBOOST banner, which runs edge to edge across the
            // top, and everything under it is centred. The height is fitted to the content once it's laid out.
            const int W = 600, Pad = 20, TextW = W - 2 * Pad;
            ClientSize = new Size(W, 700);

            int bannerH = 0;
            using (var st = typeof(AboutForm).Assembly.GetManifestResourceStream("SupportBanner.jpg"))
                if (st != null)
                {
                    var img = Image.FromStream(st);
                    bannerH = (int)Math.Round(img.Height * (W / (double)img.Width));
                    banner = new PictureBox { Image = img, SizeMode = PictureBoxSizeMode.Zoom, Location = Point.Empty, Size = new Size(W, bannerH), Cursor = Cursors.Hand, Margin = Padding.Empty };
                    banner.Click += (s, e) => Shell.Open("https://macsboost.com");
                    Controls.Add(banner);
                }

            body = new TableLayoutPanel { Location = new Point(0, bannerH), Width = W, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 1, Padding = new Padding(Pad, 14, Pad, 16), MinimumSize = new Size(W, 0), MaximumSize = new Size(W, 0) };
            body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, TextW));
            Controls.Add(body);
            void Add(Control c, int above = 0, int below = 6)
            {
                c.Anchor = AnchorStyles.None;                          // centred in the column
                c.Margin = new Padding(0, above, 0, below);
                body.Controls.Add(c);
            }
            Label Lbl(string text, Color? color = null, Font font = null) => new Label
            {
                Text = text, AutoSize = true, MaximumSize = new Size(TextW, 0), TextAlign = ContentAlignment.MiddleCenter,
                ForeColor = color ?? Color.White, Font = font ?? Font,
            };

            Add(Lbl("BoostBar " + Updater.CurrentVersion + " is energydrinkware ⚡", Color.FromArgb(116, 251, 76), new Font("Segoe UI Semibold", 14f)));
            Add(Lbl("It's free. If you like it, buy Mac an energy drink — $" + Amount + " keeps the boost coming.\nBy Mac McAlpine · MacsBoost"), 0, 12);

            var pays = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false };
            void Pay(string text, Color c, string tip, Action act)
            {
                var b = new Button { Text = text, BackColor = c, ForeColor = Color.White, FlatStyle = FlatStyle.Flat, Width = 150, Height = 40, Margin = new Padding(5, 0, 5, 0), Font = new Font("Segoe UI Semibold", 10f) };
                b.FlatAppearance.BorderSize = 0;
                new ToolTip().SetToolTip(b, tip);
                b.Click += (s, e) => { act(); App.Shared?.Tipped(); };
                pays.Controls.Add(b);
            }
            Pay("PayPal  $" + Amount, Color.FromArgb(0, 112, 186), "Pay $" + Amount + " to " + PayEmail + " with PayPal", () =>
                Shell.Open("https://www.paypal.com/cgi-bin/webscr?cmd=_xclick&business=" + Esc(PayEmail) + "&item_name=" + Esc("BoostBar energy drink") +
                           "&amount=" + Amount + "&currency_code=USD&no_shipping=1"));
            Pay("Venmo  $" + Amount, Color.FromArgb(0, 140, 255), "Pay $" + Amount + " to @" + VenmoUser + " on Venmo", () =>
                Shell.Open("https://venmo.com/" + VenmoUser + "?txn=pay&amount=" + Amount + "&note=" + Esc("BoostBar energy drink ⚡")));
            Pay("Card  $" + Amount, Color.FromArgb(99, 91, 255), "Pay $" + Amount + " by card (Stripe) on biz-cord.com", () =>
                Shell.Open(StripeUrl + "?amount=" + Amount + "&app=BoostBar&version=" + Esc(Updater.CurrentVersion) + "&platform=windows"));
            Add(pays, 0, 8);
            Add(Lbl("Card payments are processed by Stripe on biz-cord.com.",
                     Color.FromArgb(170, 170, 170), new Font("Segoe UI", 8.5f)), 0, 14);

            Add(Lbl("More from MacsBoost", null, new Font("Segoe UI Semibold", 10.5f)), 0, 4);
            // two centred rows of links: the sites, then the socials and GitHub
            FlowLayoutPanel Row() => new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false };
            var sites = Row();
            foreach (var (title, url) in Sites) sites.Controls.Add(Link(title, url));
            Add(sites, 0, 2);
            var social = Row();
            foreach (var (title, url) in Socials) social.Controls.Add(Link(title, url));
            social.Controls.Add(Link("GitHub", Updater.RepoPage));
            Add(social, 0, 10);

            var credit = new LinkLabel { Text = "Thanks to Dave Plummer for the HDD LED inspiration — check out TMOG (Task Manager OG).", AutoSize = true, MaximumSize = new Size(TextW, 0),
                TextAlign = ContentAlignment.MiddleCenter, LinkColor = Color.FromArgb(116, 251, 76), ForeColor = Color.FromArgb(200, 200, 200) };
            credit.Links.Add(credit.Text.IndexOf("TMOG"), "TMOG (Task Manager OG)".Length, "https://tmog.org");
            credit.LinkClicked += (s, e) => Shell.Open((string)e.Link.LinkData);
            Add(credit, 0, 8);
            Add(Lbl("Free to use either way — may the boost be with you!"), 0, 10);
            var small = new Font("Segoe UI", 8.5f);
            Add(Lbl("BoostBar sends biz-cord.com one anonymous install count per version (no personal info). Turn it off in Settings ▸ General.", Color.FromArgb(150, 150, 150), small));
            Add(Lbl("© 2026 MacsBoost / X1 Racing · Mac McAlpine · MIT License", Color.FromArgb(150, 150, 150), small), 0, 0);
            FitToContent();
        }

        PictureBox banner;
        TableLayoutPanel body;

        /// The window hugs the banner's width and the content's height (after any DPI scaling has been applied).
        void FitToContent()
        {
            if (body == null) return;
            body.PerformLayout();
            var w = banner != null ? banner.Width : body.Width;
            ClientSize = new Size(w, body.Bottom);
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            FitToContent();
            CenterToScreen();
        }

        static LinkLabel Link(string title, string url)
        {
            var l = new LinkLabel { Text = title, AutoSize = true, LinkColor = Color.FromArgb(116, 251, 76), ActiveLinkColor = Color.White, Margin = new Padding(7, 0, 7, 2) };
            l.LinkClicked += (s, e) => Shell.Open(url);
            return l;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
            base.OnFormClosing(e);
        }
    }
}
