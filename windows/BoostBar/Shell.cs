using System;
using System.Diagnostics;

namespace BoostBar
{
    static class Shell
    {
        public struct Result { public int Status; public string Output; }

        /// Runs a console program without a window and returns its exit code and output.
        public static Result Run(string file, string args, int timeoutMs = 10000)
        {
            try
            {
                var psi = new ProcessStartInfo(file, args)
                {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                };
                using (var p = Process.Start(psi))
                {
                    var outText = p.StandardOutput.ReadToEndAsync();
                    var errText = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } return new Result { Status = -1, Output = "" }; }
                    return new Result { Status = p.ExitCode, Output = outText.Result + errText.Result };
                }
            }
            catch (Exception e) { return new Result { Status = -1, Output = e.Message }; }
        }

        /// Runs a command elevated (Windows shows the UAC prompt). Returns false if declined or it failed.
        public static bool RunElevated(string file, string args, int timeoutMs = 60000)
        {
            try
            {
                var psi = new ProcessStartInfo(file, args) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
                using (var p = Process.Start(psi))
                {
                    if (p == null) return false;
                    if (!p.WaitForExit(timeoutMs)) return false;
                    return p.ExitCode == 0;
                }
            }
            catch { return false; }   // user said No
        }

        public static void Open(string urlOrPath)
        {
            try { Process.Start(new ProcessStartInfo(urlOrPath) { UseShellExecute = true }); } catch { }
        }
    }
}
