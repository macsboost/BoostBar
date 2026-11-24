using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace BoostBar
{
    /// One network connection (Wi‑Fi, a LAN port, a phone hotspot, …) with its own traffic history.
    class NetLink
    {
        public enum LinkKind { Ethernet = 0, WiFi = 1, Other = 2 }
        public string Id;          // adapter GUID
        public LinkKind Kind;
        public string Name;        // adapter description, e.g. "Intel(R) Wi-Fi 6 AX201"
        public string Short;       // "Wi‑Fi", "LAN", "LAN 2", …
        public History Up = new History(30), Down = new History(30);
        public History LongUp = new History(300), LongDown = new History(300);
        public bool Active;
        public double CurrentUp => Up.Last;
        public double CurrentDown => Down.Last;
        public long LastRx, LastTx;
        public bool HasLast;
    }

    /// Samples bytes in/out once a second across physical adapters (64-bit counters).
    /// Skips loopback, tunnels and virtual switches (VPN, Hyper-V, VMware…) so traffic isn't counted twice.
    class NetworkMonitor
    {
        public readonly History Up = new History(30), Down = new History(30);
        public readonly History LongUp = new History(300), LongDown = new History(300);
        readonly Dictionary<string, NetLink> table = new Dictionary<string, NetLink>();
        readonly Stopwatch clock = Stopwatch.StartNew();
        double lastT = -1;

        public double CurrentUp => Up.Last;
        public double CurrentDown => Down.Last;

        public List<NetLink> ActiveLinks =>
            table.Values.Where(l => l.Active).OrderBy(l => (int)l.Kind).ThenBy(l => l.Short).ToList();

        public NetLink Link(string id) => id != null && table.TryGetValue(id, out var l) ? l : null;

        static readonly string[] VirtualWords =
        {
            "virtual", "vpn", "tap-", "tap ", "tun", "hyper-v", "vmware", "virtualbox", "loopback", "pseudo", "miniport",
            "wireguard", "tailscale", "zerotier", "npcap", "teredo", "isatap", "6to4", "bluetooth", "wi-fi direct", "kernel debug",
        };

        static bool IsPhysical(NetworkInterface n)
        {
            switch (n.NetworkInterfaceType)
            {
                case NetworkInterfaceType.Loopback:
                case NetworkInterfaceType.Tunnel:
                case NetworkInterfaceType.Ppp:
                    return false;
            }
            var d = (n.Description + " " + n.Name).ToLowerInvariant();
            return !VirtualWords.Any(w => d.Contains(w));
        }

        static bool HasRoutableAddress(NetworkInterface n)
        {
            try
            {
                foreach (var a in n.GetIPProperties().UnicastAddresses)
                {
                    var ip = a.Address;
                    if (ip.AddressFamily == AddressFamily.InterNetwork)
                    {
                        var b = ip.GetAddressBytes();
                        if (!(b[0] == 169 && b[1] == 254) && b[0] != 127) return true;
                    }
                    else if (ip.AddressFamily == AddressFamily.InterNetworkV6 && !ip.IsIPv6LinkLocal && !ip.Equals(System.Net.IPAddress.IPv6Loopback))
                        return true;
                }
            }
            catch { }
            return false;
        }

        /// Call once a second.
        public void Sample()
        {
            var now = clock.Elapsed.TotalSeconds;
            var dt = lastT < 0 ? 0 : now - lastT;
            lastT = now;
            NetworkInterface[] all;
            try { all = NetworkInterface.GetAllNetworkInterfaces(); } catch { return; }

            double totUp = 0, totDown = 0;
            var seen = new HashSet<string>();
            foreach (var n in all)
            {
                if (!IsPhysical(n)) continue;
                long rx, tx;
                try { var s = n.GetIPStatistics(); rx = s.BytesReceived; tx = s.BytesSent; } catch { continue; }
                seen.Add(n.Id);
                if (!table.TryGetValue(n.Id, out var l))
                {
                    l = new NetLink { Id = n.Id };
                    table[n.Id] = l;
                }
                l.Kind = n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? NetLink.LinkKind.WiFi
                       : n.NetworkInterfaceType == NetworkInterfaceType.Ethernet || n.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet
                         || n.NetworkInterfaceType == NetworkInterfaceType.FastEthernetT ? NetLink.LinkKind.Ethernet : NetLink.LinkKind.Other;
                l.Name = n.Description;
                l.Active = n.OperationalStatus == OperationalStatus.Up && HasRoutableAddress(n);
                double up = 0, down = 0;
                if (l.HasLast && dt > 0.2)
                {
                    up = Math.Max(0, tx - l.LastTx) / dt;
                    down = Math.Max(0, rx - l.LastRx) / dt;
                    if (up > 1e11 || down > 1e11) { up = 0; down = 0; }   // counter reset
                }
                l.LastRx = rx; l.LastTx = tx; l.HasLast = true;
                if (dt > 0)
                {
                    l.Up.Append(up); l.Down.Append(down); l.LongUp.Append(up); l.LongDown.Append(down);
                    if (l.Active) { totUp += up; totDown += down; }
                }
            }
            foreach (var gone in table.Keys.Where(k => !seen.Contains(k)).ToList()) table.Remove(gone);
            NameLinks();
            if (dt > 0) { Up.Append(totUp); Down.Append(totDown); LongUp.Append(totUp); LongDown.Append(totDown); }
        }

        void NameLinks()
        {
            int lan = 0, wifi = 0;
            foreach (var l in table.Values.Where(x => x.Active).OrderBy(x => (int)x.Kind).ThenBy(x => x.Id))
            {
                switch (l.Kind)
                {
                    case NetLink.LinkKind.WiFi: wifi++; l.Short = wifi > 1 ? "Wi‑Fi " + wifi : "Wi‑Fi"; break;
                    case NetLink.LinkKind.Ethernet: lan++; l.Short = lan > 1 ? "LAN " + lan : "LAN"; break;
                    default:
                        var d = (l.Name ?? "").ToLowerInvariant();
                        l.Short = d.Contains("iphone") || d.Contains("apple mobile") ? "iPhone"
                                : d.Contains("android") || d.Contains("rndis") || d.Contains("remote ndis") ? "Phone"
                                : d.Contains("cellular") || d.Contains("mobile broadband") || d.Contains("wwan") ? "Cellular" : "Net";
                        break;
                }
            }
        }

        // ---- Wi‑Fi network name (from netsh, refreshed in the background) ----
        static string ssid;
        static DateTime ssidAt = DateTime.MinValue;
        static bool ssidBusy;
        public static string WiFiLine()
        {
            if ((DateTime.UtcNow - ssidAt).TotalSeconds > 15 && !ssidBusy)
            {
                ssidBusy = true;
                Task.Run(() =>
                {
                    try
                    {
                        var r = Shell.Run("netsh", "wlan show interfaces", 4000);
                        string found = null;
                        foreach (var line in r.Output.Split('\n'))
                        {
                            var t = line.Trim();
                            if (t.StartsWith("SSID", StringComparison.OrdinalIgnoreCase) && !t.StartsWith("BSSID", StringComparison.OrdinalIgnoreCase))
                            {
                                var i = t.IndexOf(':');
                                if (i > 0) { found = t.Substring(i + 1).Trim(); break; }
                            }
                        }
                        ssid = string.IsNullOrEmpty(found) ? null : found;
                    }
                    catch { ssid = null; }
                    ssidAt = DateTime.UtcNow;
                    ssidBusy = false;
                });
            }
            return ssid == null ? null : "Network: " + ssid;
        }
    }
}
