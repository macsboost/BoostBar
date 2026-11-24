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
        static readonly (string Title, string Url)[] Socials = { ("@realx1racing", "https://x.com/realx1racing"), ("@macsboost", "https://x.com/macsboost") };

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
            ClientSize = new Size(520, 640);

            var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(20, 16, 20, 16), AutoScroll = true };
            Controls.Add(flow);

            using (var st = typeof(AboutForm).Assembly.GetManifestResourceStream("SupportBanner.jpg"))
                if (st != null)
                {
                    var img = Image.FromStream(st);
                    var w = 480; var h = (int)(img.Height * (w / (double)img.Width));
                    var pb = new PictureBox { Image = img, SizeMode = PictureBoxSizeMode.Zoom, Width = w, Height = h, Cursor = Cursors.Hand, Margin = new Padding(0, 0, 0, 10) };
                    pb.Click += (s, e) => Shell.Open("https://macsboost.com");
                    flow.Controls.Add(pb);
                }

            flow.Controls.Add(new Label { Text = "BoostBar " + Updater.CurrentVersion + " is energydrinkware ⚡", Font = new Font("Segoe UI Semibold", 14f), AutoSize = true, ForeColor = Color.FromArgb(116, 251, 76) });
            flow.Controls.Add(new Label { Text = "It's free. If you like it, buy me an energy drink — $" + Amount + " keeps the boost coming.\nBy Mac McAlpine · MacsBoost", AutoSize = true, MaximumSize = new Size(480, 0), Margin = new Padding(0, 6, 0, 10) });

            var pays = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(490, 0) };
            void Pay(string text, Color c, string tip, Action act)
            {
                var b = new Button { Text = text, BackColor = c, ForeColor = Color.White, FlatStyle = FlatStyle.Flat, Width = 150, Height = 40, Margin = new Padding(0, 0, 10, 8), Font = new Font("Segoe UI Semibold", 10f) };
                b.FlatAppearance.BorderSize = 0;
                new ToolTip().SetToolTip(b, tip);
                b.Click += (s, e) => act();
                pays.Controls.Add(b);
            }
            Pay("PayPal  $" + Amount, Color.FromArgb(0, 112, 186), "Pay $" + Amount + " to " + PayEmail + " with PayPal", () =>
                Shell.Open("https://www.paypal.com/cgi-bin/webscr?cmd=_xclick&business=" + Esc(PayEmail) + "&item_name=" + Esc("BoostBar energy drink") +
                           "&amount=" + Amount + "&currency_code=USD&no_shipping=1"));
            Pay("Venmo  $" + Amount, Color.FromArgb(0, 140, 255), "Pay $" + Amount + " to @" + VenmoUser + " on Venmo", () =>
                Shell.Open("https://venmo.com/" + VenmoUser + "?txn=pay&amount=" + Amount + "&note=" + Esc("BoostBar energy drink ⚡")));
            Pay("Card  $" + Amount, Color.FromArgb(99, 91, 255), "Pay $" + Amount + " by card (Stripe) on biz-cord.com", () =>
                Shell.Open(StripeUrl + "?amount=" + Amount + "&app=BoostBar&version=" + Esc(Updater.CurrentVersion) + "&platform=windows"));
            flow.Controls.Add(pays);
            flow.Controls.Add(new Label { Text = "Card payments are processed by Stripe on biz-cord.com. Apple Cash works too, from an iPhone: send $" + Amount + " to " + PayEmail + ".", AutoSize = true, MaximumSize = new Size(480, 0), ForeColor = Color.FromArgb(170, 170, 170), Margin = new Padding(0, 0, 0, 12) });

            flow.Controls.Add(new Label { Text = "More from MacsBoost", Font = new Font("Segoe UI Semibold", 10.5f), AutoSize = true, Margin = new Padding(0, 4, 0, 4) });
            var links = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(490, 0) };
            foreach (var (title, url) in Sites) links.Controls.Add(Link(title, url));
            foreach (var (title, url) in Socials) links.Controls.Add(Link(title, url));
            links.Controls.Add(Link("GitHub", Updater.RepoPage));
            flow.Controls.Add(links);

            var credit = new LinkLabel { Text = "Thanks to Dave Plummer for the HDD LED inspiration — check out TMOG (Task Manager OG).", AutoSize = true, MaximumSize = new Size(480, 0),
                LinkColor = Color.FromArgb(116, 251, 76), ForeColor = Color.FromArgb(200, 200, 200), Margin = new Padding(0, 12, 0, 4) };
            credit.Links.Add(credit.Text.IndexOf("TMOG"), "TMOG (Task Manager OG)".Length, "https://tmog.org");
            credit.LinkClicked += (s, e) => Shell.Open((string)e.Link.LinkData);
            flow.Controls.Add(credit);
            flow.Controls.Add(new Label { Text = "Free to use either way — may the boost be with you!", AutoSize = true, Margin = new Padding(0, 8, 0, 4) });
            flow.Controls.Add(new Label { Text = "BoostBar sends biz-cord.com one anonymous install count per version (no personal info). Turn it off in Settings ▸ General.", AutoSize = true, MaximumSize = new Size(480, 0), ForeColor = Color.FromArgb(150, 150, 150), Font = new Font("Segoe UI", 8.5f) });
            flow.Controls.Add(new Label { Text = "© 2026 MacsBoost / X1 Racing · Mac McAlpine · MIT License", AutoSize = true, ForeColor = Color.FromArgb(150, 150, 150), Font = new Font("Segoe UI", 8.5f), Margin = new Padding(0, 6, 0, 0) });
        }

        static LinkLabel Link(string title, string url)
        {
            var l = new LinkLabel { Text = title, AutoSize = true, LinkColor = Color.FromArgb(116, 251, 76), ActiveLinkColor = Color.White, Margin = new Padding(0, 0, 14, 4) };
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
