using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BoostBar
{
    /// The three screen savers installed next to BoostBar.exe: preview, make active, start.
    /// Unlike on the Mac, Windows lets an app choose the screen saver, so "Use as My Screen Saver" is one click.
    static class ScreenSavers
    {
        const string DesktopKey = @"Control Panel\Desktop";

        public static string PathFor(string scene) => Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), SaverConfig.ScrName(scene));
        public static bool Installed(string scene) => File.Exists(PathFor(scene));

        public static string Blurb(string scene)
        {
            switch (scene)
            {
                case "starships": return "Starships glide across the screen, flaps beating like wings, Raptors glowing.";
                case "starlink": return "Starlink V2 and V3 satellites beat their solar wings like birds; some arrive folded and unfurl their arrays.";
                default: return "X1 SkyRacers fly across the screen in a loose flock, rotors and thruster fans spinning.";
            }
        }

        public static (string Id, string Name)[] Choices(string scene)
        {
            switch (scene)
            {
                case "starlink": return new[] { ("v15", "Starlink V1.5"), ("v2", "Starlink V2"), ("v3", "Starlink V3"), ("deploy", "V3 deploying") };
                case "cars": return new[] { ("macsboost", "MacsBoost livery"), ("yonder", "Yonder 01 livery"), ("xxone", "XXONE 51 livery") };
                default: return new (string, string)[0];
            }
        }

        /// The screen saver Windows runs now (full path), or null.
        public static string Active
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(DesktopKey))
                    {
                        var on = k?.GetValue("ScreenSaveActive") as string;
                        var exe = k?.GetValue("SCRNSAVE.EXE") as string;
                        return on == "0" || string.IsNullOrEmpty(exe) ? null : exe;
                    }
                }
                catch { return null; }
            }
        }

        static bool SamePath(string a, string b)
        {
            try { return string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); } catch { return false; }
        }

        public static string Status(string scene)
        {
            if (!Installed(scene)) return "The screen saver files aren't installed — reinstall BoostBar to get them.";
            var a = Active;
            if (a != null && (SamePath(a, PathFor(scene)) || SamePath(a, Native.ShortPath(PathFor(scene))))) return "✓ This is your screen saver now.";
            if (a == null) return "No screen saver is turned on in Windows.";
            return "Your screen saver now: " + Path.GetFileNameWithoutExtension(a) + ".";
        }

        /// Starts a screen saver program directly. Not through the shell: other apps (Autodesk EAGLE, for one) register
        /// the .scr extension for their own script files, and the shell would open the file in them.
        static void Launch(string path, string args)
        {
            Process.Start(new ProcessStartInfo(path, args) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(path) });
        }

        public static void Preview(string scene)
        {
            if (!Installed(scene)) { Updater.Alert("Screen saver missing", Status(scene)); return; }
            try { Launch(PathFor(scene), "/w"); } catch (Exception e) { Updater.Alert("Couldn't start the preview", e.Message); }
        }

        public static void Run(string scene)
        {
            if (!Installed(scene)) { Updater.Alert("Screen saver missing", Status(scene)); return; }
            try { Launch(PathFor(scene), "/s"); } catch { }
        }

        /// Starts whatever screen saver Windows has chosen (ours if none is set).
        public static void StartNow()
        {
            var a = Active;
            try
            {
                if (a != null && File.Exists(a)) Launch(a, "/s");
                else Run("cars");
            }
            catch { }
        }

        public static void Use(string scene)
        {
            if (!Installed(scene)) { Updater.Alert("Screen saver missing", Status(scene)); return; }
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(DesktopKey))
                {
                    k.SetValue("SCRNSAVE.EXE", Native.ShortPath(PathFor(scene)));
                    k.SetValue("ScreenSaveActive", "1");
                    var t = k.GetValue("ScreenSaveTimeOut") as string;
                    if (string.IsNullOrEmpty(t) || t == "0") k.SetValue("ScreenSaveTimeOut", "600");
                }
                Native.SystemParametersInfo(Native.SPI_SETSCREENSAVEACTIVE, 1, IntPtr.Zero, Native.SPIF_UPDATEINIFILE | Native.SPIF_SENDCHANGE);
            }
            catch (Exception e) { Updater.Alert("Couldn't set the screen saver", e.Message); }
        }

        /// Windows' own Screen Saver Settings dialog (timeout, "On resume, display logon screen", its Preview button).
        /// `control desk.cpl` alone lands in the Settings app instead.
        public static void OpenWindowsSettings()
        {
            var sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
            try { Process.Start(new ProcessStartInfo(Path.Combine(sys, "rundll32.exe"), "shell32.dll,Control_RunDLL desk.cpl,screensaver,@screensaver") { UseShellExecute = false }); }
            catch { try { Process.Start(new ProcessStartInfo(Path.Combine(sys, "control.exe"), "desk.cpl,,@screensaver") { UseShellExecute = false }); } catch { } }
        }
    }
}
