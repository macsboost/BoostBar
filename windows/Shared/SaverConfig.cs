using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace BoostBar
{
    /// Screen saver options, edited in BoostBar ▸ Settings ▸ Screen Saver and read by BoostBarSaver.scr.
    /// Same fields as the Mac version's "BoostBar Screen Savers.json".
    class SaverOptions
    {
        public int Count;
        public double Speed = 1, FlapSpeed = 1, Oxidation = 0.35;
        public bool Stunts = true, Stars = true;
        public List<string> Liveries = new List<string>();
        public double? Tilt;
        /// Flock angle in degrees (0 = right, 90 = up); null = the classic down-left.
        public double? Heading;
        public bool Crossing, Lasers, Clouds, Roadster, RoadsterStable;
    }

    static class SaverConfig
    {
        public static readonly string[] Scenes = { "cars", "starships", "starlink" };

        public static string Title(string scene) =>
            scene == "starships" ? "BoostBar Starships" : scene == "starlink" ? "BoostBar Starlink" : "BoostBar Flying Cars";

        /// File name of the installed screen saver for a scene (no spaces: Windows keeps SCRNSAVE.EXE paths simple).
        public static string ScrName(string scene) =>
            scene == "starships" ? "BoostBarStarships.scr" : scene == "starlink" ? "BoostBarStarlink.scr" : "BoostBarFlyingCars.scr";

        public static string SceneFromExe(string exePath)
        {
            var n = Path.GetFileNameWithoutExtension(exePath ?? "").ToLowerInvariant();
            if (n.Contains("starship")) return "starships";
            if (n.Contains("starlink")) return "starlink";
            return "cars";
        }

        public static string Dir =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BoostBar");

        public static string FilePath => Path.Combine(Dir, "Screen Savers.json");

        public static SaverOptions Defaults(string scene)
        {
            switch (scene)
            {
                case "starships": return new SaverOptions { Count = 6, Roadster = true };
                case "starlink": return new SaverOptions { Count = 5, Liveries = new List<string> { "v15", "v2", "v3", "deploy" }, Crossing = true, Lasers = true };
                default: return new SaverOptions { Count = 7, Liveries = new List<string> { "macsboost", "yonder", "xxone" } };
            }
        }

        /// The flock's classic direction of travel, down and to the left like the flying bread (~207.5°).
        public static readonly double DefaultHeading = Math.Atan2(-0.52, -1) * 180 / Math.PI + 360;

        /// "208° ↙": a flock angle with an arrow showing which way they fly.
        public static string HeadingText(double deg)
        {
            var a = ((deg % 360) + 360) % 360;
            string[] arrows = { "→", "↗", "↑", "↖", "←", "↙", "↓", "↘" };
            return a.ToString("0") + "° " + arrows[(int)Math.Round(a / 45) % 8];
        }

        public static double DefaultTilt(string scene) => scene == "starships" ? -11.5 : scene == "starlink" ? -66 : -32;

        public static SaverOptions Load(string scene)
        {
            var o = Defaults(scene);
            try
            {
                if (!File.Exists(FilePath)) return o;
                var all = Json.Parse(File.ReadAllText(FilePath));
                if (all == null || !all.TryGetValue(scene, out var raw) || !(raw is Dictionary<string, object> d)) return o;
                o.Count = (int)d.Num("count", o.Count);
                o.Speed = d.Num("speed", o.Speed);
                o.FlapSpeed = d.Num("flapSpeed", o.FlapSpeed);
                o.Oxidation = d.Num("oxidation", o.Oxidation);
                o.Stunts = d.Bool("stunts") ?? o.Stunts;
                o.Stars = d.Bool("stars") ?? o.Stars;
                if (d.TryGetValue("tilt", out var t) && t != null) o.Tilt = d.Num("tilt", DefaultTilt(scene));
                if (d.TryGetValue("heading", out var hd) && hd != null) o.Heading = d.Num("heading", DefaultHeading);
                o.Crossing = d.Bool("crossing") ?? o.Crossing;
                o.Lasers = d.Bool("lasers") ?? o.Lasers;
                o.Clouds = d.Bool("clouds") ?? false;
                o.Roadster = d.Bool("roadster") ?? o.Roadster;
                o.RoadsterStable = d.Bool("roadsterStable") ?? false;
                if (d.TryGetValue("liveries", out var l) && l is System.Collections.IEnumerable list)
                    o.Liveries = list.Cast<object>().Select(x => x?.ToString()).Where(x => !string.IsNullOrEmpty(x)).ToList();
            }
            catch { }
            return o;
        }

        public static void Save(string scene, SaverOptions o)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                Dictionary<string, object> all = null;
                if (File.Exists(FilePath)) all = Json.Parse(File.ReadAllText(FilePath));
                all = all ?? new Dictionary<string, object>();
                var d = new Dictionary<string, object>
                {
                    ["count"] = o.Count, ["speed"] = o.Speed, ["flapSpeed"] = o.FlapSpeed, ["stunts"] = o.Stunts,
                    ["stars"] = o.Stars, ["liveries"] = o.Liveries, ["oxidation"] = o.Oxidation,
                    ["crossing"] = o.Crossing, ["lasers"] = o.Lasers, ["clouds"] = o.Clouds,
                    ["roadster"] = o.Roadster, ["roadsterStable"] = o.RoadsterStable,
                    ["savedAt"] = (DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds,
                };
                if (o.Tilt.HasValue) d["tilt"] = o.Tilt.Value;
                if (o.Heading.HasValue) d["heading"] = o.Heading.Value;
                all[scene] = d;
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, Json.Write(all));
                if (File.Exists(FilePath)) File.Delete(FilePath);
                File.Move(tmp, FilePath);
            }
            catch { }
        }

        static string B(bool b) => b ? "true" : "false";
        static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);

        /// `window.SAVER_CONFIG = …` for the page, run before it loads.
        public static string Script(string scene, bool preview = false)
        {
            var o = Load(scene);
            var livs = string.Join(",", o.Liveries.Select(x => "\"" + x.Replace("\"", "") + "\""));
            return "window.SAVER_CONFIG={liveries:[" + livs + "],count:" + o.Count + ",speed:" + N(o.Speed) +
                   ",flapSpeed:" + N(o.FlapSpeed) + ",stunts:" + B(o.Stunts) + ",stars:" + B(o.Stars) +
                   ",oxidation:" + N(o.Oxidation) + ",crossing:" + B(o.Crossing) + ",lasers:" + B(o.Lasers) +
                   ",clouds:" + B(o.Clouds) + ",roadster:" + B(o.Roadster) + ",roadsterStable:" + B(o.RoadsterStable) +
                   ",tilt:" + N(o.Tilt ?? DefaultTilt(scene)) + ",heading:" + N(o.Heading ?? DefaultHeading) + ",preview:" + B(preview) + "};";
        }
    }
}
