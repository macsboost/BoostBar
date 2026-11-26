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
        // Jet Racers: who wins ("random" or a racer's number), how they celebrate, and how the race is shown.
        public string Winner = "random", Celebration = "random", Camera = "director", Follow = "leader";
        public bool Board = true, Captions;
    }

    /// The Jet Racers screen saver's choices: the value the scene page understands, and the name shown in Settings.
    static class JetRace
    {
        public static readonly (string Id, string Name)[] Winners =
        {
            ("random", "Random (a fair race)"), ("16", "Skeeter (#16) always wins"), ("8", "Skison (#8) always wins"), ("3", "Jorge (#3) always wins"),
        };
        public static readonly (string Id, string Name)[] Celebrations =
        {
            ("random", "Random"), ("shake", "Stand and shake arms"), ("bow", "Take a bow"), ("bow2", "Formal bow, one arm up"),
            ("backflip", "Backflip off the seat"), ("dab", "Dab"), ("cart", "Shopping cart dance"), ("mower", "Lawn mower"),
            ("sprinkler", "Sprinkler"), ("crane", "Crane kick"),
        };
        public static readonly (string Id, string Name)[] Cameras =
        {
            ("director", "Director (cinematic)"), ("chase", "Chase"), ("onboard", "Onboard"), ("side", "Trackside boat"), ("front", "Lead boat"),
            ("heli", "Helicopter"), ("blimp", "Overhead"), ("buoy", "Buoy cam"), ("orbit", "Drone orbit"), ("finish", "Finish line"),
        };
        public static readonly (string Id, string Name)[] Follows =
        {
            ("leader", "Race leader"), ("16", "Skeeter (#16)"), ("8", "Skison (#8)"), ("3", "Jorge (#3)"),
        };
        public static int Index((string Id, string Name)[] list, string id) { var i = Array.FindIndex(list, x => x.Id == id); return i < 0 ? 0 : i; }
        public static string Valid((string Id, string Name)[] list, string id) => list[Index(list, id)].Id;
    }

    static class SaverConfig
    {
        public static readonly string[] Scenes = { "cars", "starships", "starlink", "jetrace" };

        public static string Title(string scene) =>
            scene == "starships" ? "BoostBar Starships" : scene == "starlink" ? "BoostBar Starlink" : scene == "jetrace" ? "BoostBar Jet Racers" : "BoostBar Flying Cars";

        /// File name of the installed screen saver for a scene (no spaces: Windows keeps SCRNSAVE.EXE paths simple).
        public static string ScrName(string scene) =>
            scene == "starships" ? "BoostBarStarships.scr" : scene == "starlink" ? "BoostBarStarlink.scr" : scene == "jetrace" ? "BoostBarJetRacers.scr" : "BoostBarFlyingCars.scr";

        public static string SceneFromExe(string exePath)
        {
            var n = Path.GetFileNameWithoutExtension(exePath ?? "").ToLowerInvariant();
            if (n.Contains("starship")) return "starships";
            if (n.Contains("starlink")) return "starlink";
            if (n.Contains("jetrac")) return "jetrace";
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
                string Str(string key, (string Id, string Name)[] list, string fallback) =>
                    d.TryGetValue(key, out var v) && v != null ? JetRace.Valid(list, v.ToString()) : fallback;
                o.Winner = Str("winner", JetRace.Winners, o.Winner);
                o.Celebration = Str("celebration", JetRace.Celebrations, o.Celebration);
                o.Camera = Str("camera", JetRace.Cameras, o.Camera);
                o.Follow = Str("follow", JetRace.Follows, o.Follow);
                o.Board = d.Bool("board") ?? o.Board;
                o.Captions = d.Bool("captions") ?? o.Captions;
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
                    ["winner"] = o.Winner, ["celebration"] = o.Celebration, ["camera"] = o.Camera, ["follow"] = o.Follow,
                    ["board"] = o.Board, ["captions"] = o.Captions,
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
            if (scene == "jetrace")
                return "window.SAVER_CONFIG={winner:\"" + JetRace.Valid(JetRace.Winners, o.Winner) + "\",celebration:\"" + JetRace.Valid(JetRace.Celebrations, o.Celebration) +
                       "\",camera:\"" + JetRace.Valid(JetRace.Cameras, o.Camera) + "\",follow:\"" + JetRace.Valid(JetRace.Follows, o.Follow) +
                       "\",board:" + B(o.Board) + ",captions:" + B(o.Captions) + ",preview:" + B(preview) + "};";
            var livs = string.Join(",", o.Liveries.Select(x => "\"" + x.Replace("\"", "") + "\""));
            return "window.SAVER_CONFIG={liveries:[" + livs + "],count:" + o.Count + ",speed:" + N(o.Speed) +
                   ",flapSpeed:" + N(o.FlapSpeed) + ",stunts:" + B(o.Stunts) + ",stars:" + B(o.Stars) +
                   ",oxidation:" + N(o.Oxidation) + ",crossing:" + B(o.Crossing) + ",lasers:" + B(o.Lasers) +
                   ",clouds:" + B(o.Clouds) + ",roadster:" + B(o.Roadster) + ",roadsterStable:" + B(o.RoadsterStable) +
                   ",tilt:" + N(o.Tilt ?? DefaultTilt(scene)) + ",heading:" + N(o.Heading ?? DefaultHeading) + ",preview:" + B(preview) + "};";
        }
    }
}
