using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace BoostBar
{
    /// Tiny JSON helpers on top of the framework's JavaScriptSerializer (no NuGet needed).
    static class Json
    {
        static JavaScriptSerializer S => new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public static Dictionary<string, object> Parse(string text)
        {
            try { return S.Deserialize<Dictionary<string, object>>(text); } catch { return null; }
        }

        public static object ParseAny(string text)
        {
            try { return S.DeserializeObject(text); } catch { return null; }
        }

        public static string Write(object o) => S.Serialize(o);

        public static string Str(this Dictionary<string, object> d, string k) =>
            d != null && d.TryGetValue(k, out var v) && v != null ? v.ToString() : null;

        public static double Num(this Dictionary<string, object> d, string k, double def)
        {
            if (d == null || !d.TryGetValue(k, out var v) || v == null) return def;
            try { return System.Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture); } catch { return def; }
        }

        public static bool? Bool(this Dictionary<string, object> d, string k) =>
            d != null && d.TryGetValue(k, out var v) && v is bool b ? b : (bool?)null;
    }
}
