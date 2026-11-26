using System;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace BoostBar
{
    /// The moods the eyes can show (port of the Mac Emotion), each set off by something the PC is doing.
    enum Emotion { Sleepy, Alarmed, Angry, Sweating, Happy, Sad, Suspicious, Skeptical, Startled, Bored, Hearts }

    static class Emotions
    {
        public static readonly Emotion[] All = (Emotion[])Enum.GetValues(typeof(Emotion));
        public static string Key(Emotion e) => e.ToString().ToLowerInvariant();
        public static string Title(Emotion e) => e == Emotion.Skeptical ? "Skeptical (one-eye squint)" : e == Emotion.Hearts ? "Heart / dollar eyes" : e.ToString();
        public static string When(Emotion e)
        {
            switch (e)
            {
                case Emotion.Sleepy: return "Lids droop the longer the PC sits idle (from 3 minutes).";
                case Emotion.Alarmed: return "Wide eyes, tiny pupils: CPU pegged, or battery at 10% and unplugged.";
                case Emotion.Angry: return "Slanted lids when the CPU has been in the red for 20 seconds.";
                case Emotion.Sweating: return "A squint and a sweat drop when the CPU has been working flat out for a minute.";
                case Emotion.Happy: return "Smiling eyes for a few seconds when the charger is plugged in or a big download finishes.";
                case Emotion.Sad: return "Droopy eyes when the network is down, or the battery is at 15% and unplugged.";
                case Emotion.Suspicious: return "A narrow squint when the pointer lingers right by the eyes.";
                case Emotion.Skeptical: return "Whip the pointer fast across a big stretch of screen and one eye squints at it: the eye on the pointer's side, harder the faster you go.";
                case Emotion.Startled: return "A jump and a blink when a drive is plugged in, or the pointer moves after a long pause.";
                case Emotion.Bored: return "An eye-roll now and then when nothing has happened for a while.";
                default: return "A flash of hearts and dollar signs when a tip button is clicked.";
            }
        }
    }

    /// How the eyes are drawn for a mood: lids, slant, pupil size and the odd prop (port of the Mac EyeFace).
    class EyeFace
    {
        public float LidTop, LidBottom, Slant, PupilScale = 1, Lift, SquintL, SquintR;
        public bool Smile;
        public float Sweat = -1;   // 0…1 a drop sliding down beside the eyes; < 0 none
        public int Symbol;         // 1 hearts, 2 dollar signs

        public EyeFace Clone() => (EyeFace)MemberwiseClone();
        public bool Same(EyeFace o) => LidTop == o.LidTop && LidBottom == o.LidBottom && Slant == o.Slant && PupilScale == o.PupilScale && Lift == o.Lift
                                       && SquintL == o.SquintL && SquintR == o.SquintR && Smile == o.Smile && Sweat == o.Sweat && Symbol == o.Symbol;

        public static EyeFace Pose(Emotion e, float level = 1)
        {
            var f = new EyeFace();
            switch (e)
            {
                case Emotion.Sleepy: f.LidTop = 0.3f + 0.45f * level; break;
                case Emotion.Alarmed: f.PupilScale = 0.5f; break;
                case Emotion.Angry: f.LidTop = 0.26f; f.Slant = 0.3f; break;
                case Emotion.Sweating: f.LidTop = 0.12f; f.LidBottom = 0.22f; f.Sweat = 0.3f; break;
                case Emotion.Happy: f.Smile = true; break;
                case Emotion.Sad: f.LidTop = 0.24f; f.Slant = -0.3f; break;
                case Emotion.Suspicious: f.LidTop = 0.42f; f.LidBottom = 0.28f; break;
                case Emotion.Skeptical: f.SquintR = level; break;
                case Emotion.Startled: f.PupilScale = 0.45f; f.Lift = 1.5f; break;
                case Emotion.Bored: f.LidTop = 0.3f; break;
                case Emotion.Hearts: f.Symbol = 1; break;
            }
            return f;
        }

        public void Ease(EyeFace t, float k)
        {
            float E(float a, float b, float snap) { var v = a + (b - a) * k; return Math.Abs(v - b) < snap ? b : v; }
            LidTop = E(LidTop, t.LidTop, 0.004f); LidBottom = E(LidBottom, t.LidBottom, 0.004f); Slant = E(Slant, t.Slant, 0.004f);
            PupilScale = E(PupilScale, t.PupilScale, 0.004f); Lift = E(Lift, t.Lift, 0.02f);
            SquintL = E(SquintL, t.SquintL, 0.004f); SquintR = E(SquintR, t.SquintR, 0.004f);
            Smile = t.Smile; Sweat = t.Sweat; Symbol = t.Symbol;
        }
    }

    /// Googly eye physics (port of the Mac EyesAnimator): pupils look toward the pointer anywhere on screen,
    /// with springy overshoot, a little droop, occasional blinks, and circle-to-spin. Works in screen pixels (y down);
    /// distances are scaled by `Zoom` (pixels per strip unit) so it feels the same at any DPI.
    class EyesAnimator
    {
        public bool Googly = true, Blink = true, AllowCrossEye = true, Lazy;

        // ---- emotions ----
        public System.Collections.Generic.HashSet<Emotion> Emotions = new System.Collections.Generic.HashSet<Emotion>();
        public double CpuLoad;
        public int? BatteryPercent;
        public bool OnCharger = true, NetDown;
        EyeFace face = new EyeFace();
        (Emotion E, double From, double Until)? triggered;
        double? cpuPeggedSince, cpuHighSince, cpuFlatOutSince, hoverSince;
        double lastIdle, nextRoll, rollStart = -10;
        readonly System.Collections.Generic.List<(double T, PointF P)> trail = new System.Collections.Generic.List<(double, PointF)>();
        double skeptUntil; float skeptLevel, skeptSide;

        /// Shows a mood for a while because something just happened (a charger, a drive, a tip…).
        public void Trigger(Emotion e, double seconds, bool force = false)
        {
            if (!force && !Emotions.Contains(e)) return;
            var now = clock.Elapsed.TotalSeconds;
            triggered = (e, now, now + seconds);
        }

        /// Settings: the pointer left an emotion's checkbox, so stop previewing it.
        public void EndPreview(Emotion e) { if (triggered.HasValue && triggered.Value.E == e) triggered = null; }

        static double IdleSeconds()
        {
            var lii = new Native.LASTINPUTINFO { cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.LASTINPUTINFO)) };
            if (!Native.GetLastInputInfo(ref lii)) return 0;
            return unchecked((uint)Environment.TickCount - lii.dwTime) / 1000.0;
        }

        /// The pointer whipping across the screen: over ~1.4 screen-widths a second for half a second, and the last
        /// second's path spanning 45% of the screen's width. Faster = harder squint; it holds 1.3 s after.
        void TrackWhip(PointF mouse, PointF mid, double now)
        {
            trail.Add((now, mouse));
            trail.RemoveAll(t => now - t.T > 1.0);
            if (trail.Count < 5) return;
            var sw = (float)Screen.FromPoint(Point.Round(mouse)).Bounds.Width;
            float len = 0, x0 = mouse.X, x1 = mouse.X, y0 = mouse.Y, y1 = mouse.Y;
            for (var k = 0; k < trail.Count; k++)
            {
                var p = trail[k].P;
                x0 = Math.Min(x0, p.X); x1 = Math.Max(x1, p.X); y0 = Math.Min(y0, p.Y); y1 = Math.Max(y1, p.Y);
                if (k > 0 && now - trail[k].T <= 0.5) len += (float)Math.Sqrt(Math.Pow(p.X - trail[k - 1].P.X, 2) + Math.Pow(p.Y - trail[k - 1].P.Y, 2));
            }
            var speed = len / 0.5f / sw; var span = (float)Math.Sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) / sw;
            if (speed > 1.4f && span > 0.45f) { skeptLevel = Math.Min(1, 0.45f + (speed - 1.4f) / 3.2f); skeptUntil = now + 1.3; }
            if (now < skeptUntil) skeptSide = (mouse.X - mid.X) / sw;
        }

        (Emotion E, float Level)? Mood(double now, PointF mouse, PointF mid, float halfSpan)
        {
            var idle = IdleSeconds();
            if (lastIdle > 60 && idle < 1) Trigger(Emotion.Startled, 0.9);
            lastIdle = idle;
            bool On(Emotion e) => Emotions.Contains(e);
            if (On(Emotion.Skeptical)) TrackWhip(mouse, mid, now);
            if (triggered.HasValue)
            {
                if (now < triggered.Value.Until) return (triggered.Value.E, 1);
                triggered = null;
            }
            if (On(Emotion.Skeptical) && now < skeptUntil) return (Emotion.Skeptical, skeptLevel * (float)Math.Min(1, (skeptUntil - now) / 0.5));
            if (CpuLoad > 0.9) { if (cpuPeggedSince == null) cpuPeggedSince = now; } else cpuPeggedSince = null;
            if (CpuLoad > 0.8) { if (cpuHighSince == null) cpuHighSince = now; } else if (CpuLoad < 0.7) cpuHighSince = null;
            if (CpuLoad > 0.85) { if (cpuFlatOutSince == null) cpuFlatOutSince = now; } else if (CpuLoad < 0.75) cpuFlatOutSince = null;
            var pct = BatteryPercent ?? 100;
            if (On(Emotion.Alarmed))
            {
                if (cpuPeggedSince.HasValue && now - cpuPeggedSince.Value < 6) return (Emotion.Alarmed, 1);
                if (!OnCharger && pct <= 10 && now % 60 < 6) return (Emotion.Alarmed, 1);
            }
            if (On(Emotion.Sweating) && cpuFlatOutSince.HasValue && now - cpuFlatOutSince.Value > 60) return (Emotion.Sweating, 1);
            if (On(Emotion.Angry) && cpuHighSince.HasValue && now - cpuHighSince.Value > 20) return (Emotion.Angry, 1);
            if (On(Emotion.Sad) && (NetDown || (!OnCharger && pct <= 15))) return (Emotion.Sad, 1);
            var z = Zoom;
            var near = Math.Abs(mouse.X - mid.X) < halfSpan + 10 * z && Math.Abs(mid.Y - mouse.Y) < 14 * z;
            if (near) { if (hoverSince == null) hoverSince = now; } else hoverSince = null;
            if (On(Emotion.Suspicious) && hoverSince.HasValue && now - hoverSince.Value > 1.2) return (Emotion.Suspicious, 1);
            if (On(Emotion.Bored) && idle > 90)
            {
                if (nextRoll == 0) nextRoll = now + 4 + rnd.NextDouble() * 11;
                if (now >= nextRoll) { rollStart = now; nextRoll = now + 25 + rnd.NextDouble() * 25; }
                if (now - rollStart < 1.6) return (Emotion.Bored, (float)((now - rollStart) / 1.6));
            }
            else nextRoll = 0;
            if (On(Emotion.Sleepy) && idle > 180) return (Emotion.Sleepy, (float)Math.Min(1, (idle - 180) / 420));
            return null;
        }
        public float Zoom = 1;
        readonly Random rnd = new Random();
        readonly Stopwatch clock = Stopwatch.StartNew();
        PointF[] pos = new PointF[0], vel = new PointF[0], lazyTarget = new PointF[0];
        PointF lastMouse = new PointF(float.NaN, float.NaN);
        double nextBlink, blinkUntil;

        // circle-to-spin
        PointF lastSample = new PointF(float.NaN, float.NaN);
        double? lastHeading;
        double winding, lastTurnAt, turnRate, wheelAngle, wheelVel, lastStep;
        bool spinning;

        /// Advances one frame (call ~30×/s). `centers` are the eyes' centers on screen, `travel` how far a pupil may move
        /// (in strip units). Returns true when the strip needs redrawing.
        // The springs were tuned per 1/30 s step (as on the Mac): physics runs in fixed 30 Hz steps and the pupils
        // are drawn between the last two steps, so they move smoothly at 60 Hz and feel the same at any frame rate.
        const double PhysicsDt = 1.0 / 30;
        double acc, lastFrame;
        PointF[] prevPos = new PointF[0], shown = new PointF[0];

        public bool Step(StripRenderer v, PointF[] centers, PointF mouse)
        {
            if (centers.Length == 0) return false;
            if (pos.Length != centers.Length)
            {
                pos = new PointF[centers.Length]; vel = new PointF[centers.Length];
                prevPos = new PointF[centers.Length]; shown = new PointF[centers.Length];
            }
            if (lazyTarget.Length != centers.Length) lazyTarget = (PointF[])pos.Clone();
            var now = clock.Elapsed.TotalSeconds;
            var dt = lastFrame == 0 ? PhysicsDt : Math.Min(0.25, now - lastFrame);
            lastFrame = now;
            acc += dt;
            var steps = 0;
            while (acc >= PhysicsDt && steps < 8)
            {
                prevPos = (PointF[])pos.Clone();
                Physics(v, centers, mouse);
                acc -= PhysicsDt;
                steps++;
            }
            if (steps == 8) acc = 0;
            var alpha = (float)Math.Min(1, acc / PhysicsDt);

            var mid = new PointF(centers.Average(c => c.X), centers.Average(c => c.Y));
            var travel = v.PupilTravel;
            var halfSpan = (centers[centers.Length - 1].X - centers[0].X) / 2 + (travel.Width + 6) * Zoom;
            lastMouse = mouse;
            if (TrackCircles(mouse, mid, halfSpan, now))
            {
                v.WheelAngle = (float)wheelAngle;
                v.PupilOffsets = (PointF[])pos.Clone();
                face = new EyeFace(); v.Face = face.Clone();
                return true;
            }
            var changed = false;
            if (v.WheelAngle.HasValue)
            {
                v.WheelAngle = null;
                for (var i = 0; i < vel.Length; i++) vel[i] = new PointF((float)(rnd.NextDouble() * 4 - 2), (float)(rnd.NextDouble() * 3 - 1.5));
                changed = true;
            }
            for (var i = 0; i < pos.Length; i++)
            {
                var p = new PointF(prevPos[i].X + (pos[i].X - prevPos[i].X) * alpha, prevPos[i].Y + (pos[i].Y - prevPos[i].Y) * alpha);
                if (Math.Abs(p.X - shown[i].X) > 0.01f || Math.Abs(p.Y - shown[i].Y) > 0.01f) { shown[i] = p; changed = true; }
            }
            // the mood: pose the lids, and let a few moods move the pupils themselves (screen y is down)
            var target = new EyeFace();
            var startledBlink = false;
            var travelS = travel;
            var mood = Mood(now, mouse, mid, halfSpan);
            if (mood.HasValue)
            {
                var (emotion, level) = mood.Value;
                target = EyeFace.Pose(emotion, level);
                switch (emotion)
                {
                    case Emotion.Bored:
                        var a = level * 2 * Math.PI;
                        for (var i = 0; i < shown.Length; i++) shown[i] = new PointF((float)Math.Sin(a) * travelS.Width * 0.85f, -(float)Math.Cos(a) * travelS.Height * 0.85f);
                        changed = true; break;
                    case Emotion.Sleepy:
                        for (var i = 0; i < shown.Length; i++) shown[i].Y = Math.Min(travelS.Height, shown[i].Y + travelS.Height * 0.5f * level);
                        changed = true; break;
                    case Emotion.Sad:
                        for (var i = 0; i < shown.Length; i++) shown[i].Y = Math.Max(shown[i].Y, travelS.Height * 0.45f);
                        changed = true; break;
                    case Emotion.Alarmed:
                        for (var i = 0; i < shown.Length; i++) { shown[i].X += (float)(rnd.NextDouble() * 0.7 - 0.35); shown[i].Y += (float)(rnd.NextDouble() * 0.7 - 0.35); }
                        changed = true; break;
                    case Emotion.Sweating:
                        target.Sweat = (float)(now / 1.6 % 1); changed = true; break;
                    case Emotion.Startled:
                        var t = now - (triggered?.From ?? now);
                        target.Lift = t < 0.22 ? 1.5f : 0;
                        startledBlink = t > 0.45 && t < 0.6; break;
                    case Emotion.Skeptical:
                        // the eye on the pointer's side squints; with the pointer right above the eyes, both do a little
                        var w = Math.Min(1, Math.Abs(skeptSide) / 0.15f);
                        float main = level, other = level * (1 - w) * 0.6f;
                        if (skeptSide < 0) { target.SquintL = main; target.SquintR = other; } else { target.SquintR = main; target.SquintL = other; }
                        if (triggered?.E == Emotion.Skeptical) { target.SquintR = level; target.SquintL = 0; }   // "Try one": the right eye
                        break;
                    case Emotion.Hearts:
                        target.Symbol = (int)((now - (triggered?.From ?? now)) / 1.2) % 2 == 0 ? 1 : 2;
                        target.PupilScale = 1 + 0.18f * (float)Math.Sin(now * 9);
                        changed = true; break;
                }
            }
            var beforeFace = face.Clone();
            face.Ease(target, (float)(1 - Math.Pow(1 - 0.28, dt * 30)));
            if (!face.Same(beforeFace) || v.Face == null || !face.Same(v.Face)) { v.Face = face.Clone(); changed = true; }

            var closed = startledBlink;
            if (Blink && !closed && !face.Smile)
            {
                if (nextBlink == 0) nextBlink = now + 3 + rnd.NextDouble() * 5;
                if (now >= nextBlink) { blinkUntil = now + 0.13; nextBlink = now + 3.5 + rnd.NextDouble() * 5.5; }
                closed = closed || now < blinkUntil;
            }
            if (closed != v.EyesClosed) changed = true;
            if (changed) { v.PupilOffsets = (PointF[])shown.Clone(); v.EyesClosed = closed; }
            return changed;
        }

        /// One 1/30 s step of the pupil springs. Returns true while anything is still moving.
        bool Physics(StripRenderer v, PointF[] centers, PointF mouse)
        {
            var travel = v.PupilTravel;
            var moving = false;
            var mid = new PointF(centers.Average(c => c.X), centers.Average(c => c.Y));
            var z = Zoom;
            var betweenEyes = centers.Length > 1 && AllowCrossEye && mouse.X > centers[0].X && mouse.X < centers[centers.Length - 1].X && Math.Abs(mouse.Y - mid.Y) < 30 * z;
            for (var i = 0; i < centers.Length; i++)
            {
                var origin = AllowCrossEye ? centers[i] : mid;
                double dx = mouse.X - origin.X, dy = mouse.Y - origin.Y;
                var dist = Math.Sqrt(dx * dx + dy * dy);
                var reach = betweenEyes ? 1 : Math.Min(1, dist / (60 * z));
                var target = dist > 0.01 ? new PointF((float)(dx / dist * travel.Width * reach), (float)(dy / dist * travel.Height * reach)) : PointF.Empty;
                if (Lazy)
                {
                    lazyTarget[i].X += (target.X - lazyTarget[i].X) * 0.035f;
                    lazyTarget[i].Y += (target.Y - lazyTarget[i].Y) * 0.035f;
                    if (Math.Abs(target.X - lazyTarget[i].X) + Math.Abs(target.Y - lazyTarget[i].Y) > 0.02f) moving = true;
                    target = lazyTarget[i];
                }
                else lazyTarget[i] = target;
                if (Googly)
                {
                    target.Y += travel.Height * 0.18f;    // googly pupils sag a little
                    vel[i].X = (vel[i].X + (target.X - pos[i].X) * 0.22f) * 0.80f;
                    vel[i].Y = (vel[i].Y + (target.Y - pos[i].Y) * 0.22f) * 0.80f;
                    pos[i].X += vel[i].X; pos[i].Y += vel[i].Y;
                    var nx = pos[i].X / Math.Max(travel.Width, 0.1f); var ny = pos[i].Y / Math.Max(travel.Height, 0.1f);
                    var r = (float)Math.Sqrt(nx * nx + ny * ny);
                    if (r > 1) { pos[i].X /= r; pos[i].Y /= r; vel[i].X *= -0.5f; vel[i].Y *= -0.5f; }   // bounce off the rim
                    if (Math.Abs(vel[i].X) > 0.01f || Math.Abs(vel[i].Y) > 0.01f) moving = true;
                }
                else if (pos[i] != target) { pos[i] = target; moving = true; }
            }
            return moving;
        }

        bool TrackCircles(PointF mouse, PointF mid, float halfSpan, double now)
        {
            var dt = lastStep == 0 ? 1.0 / 30 : Math.Min(0.1, now - lastStep);
            lastStep = now;
            var z = Zoom;
            var near = Math.Abs(mouse.X - mid.X) < halfSpan + 16 * z && Math.Abs(mid.Y - mouse.Y) < 24 * z;
            var circling = false;
            if (float.IsNaN(lastSample.X)) lastSample = mouse;
            double dx = mouse.X - lastSample.X, dy = -(mouse.Y - lastSample.Y);   // y up, like the Mac, so the wheel turns the same way
            if (Math.Sqrt(dx * dx + dy * dy) >= 3 * z)
            {
                var hd = Math.Atan2(dy, dx);
                if (lastHeading.HasValue && near)
                {
                    var d = hd - lastHeading.Value;
                    while (d > Math.PI) d -= 2 * Math.PI;
                    while (d < -Math.PI) d += 2 * Math.PI;
                    if (d != 0 && (winding == 0 || (d > 0) == (winding > 0) || Math.Abs(d) < 0.15)) winding += d;
                    else if (Math.Abs(d) >= 0.15) winding = d;
                    var rate = d / dt;
                    turnRate += (rate - turnRate) * 0.25;
                    if (Math.Abs(d) > 0.02) lastTurnAt = now;
                }
                else if (!near) winding = 0;
                lastHeading = hd;
                lastSample = mouse;
            }
            if (now - lastTurnAt > 0.45) { winding = 0; turnRate *= 0.7; }
            else circling = Math.Abs(turnRate) > 2.0;

            if (!spinning && Math.Abs(winding) >= 5 * Math.PI) { spinning = true; wheelVel = 0; wheelAngle = 0; }
            if (!spinning) return false;
            if (circling)
            {
                var target = Math.Max(-20, Math.Min(20, turnRate * 1.15));
                wheelVel += (target - wheelVel) * 0.12;
            }
            else wheelVel *= Math.Pow(0.55, dt);
            wheelAngle += wheelVel * dt;
            if (!circling && Math.Abs(wheelVel) < 0.9) { spinning = false; winding = 0; return false; }
            return true;
        }
    }
}
