using System;
using System.Diagnostics;
using System.Drawing;
using System.Linq;

namespace BoostBar
{
    /// Googly eye physics (port of the Mac EyesAnimator): pupils look toward the pointer anywhere on screen,
    /// with springy overshoot, a little droop, occasional blinks, and circle-to-spin. Works in screen pixels (y down);
    /// distances are scaled by `Zoom` (pixels per strip unit) so it feels the same at any DPI.
    class EyesAnimator
    {
        public bool Googly = true, Blink = true, AllowCrossEye = true, Lazy;
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
        public bool Step(StripRenderer v, PointF[] centers, PointF mouse)
        {
            if (centers.Length == 0) return false;
            if (pos.Length != centers.Length) { pos = new PointF[centers.Length]; vel = new PointF[centers.Length]; }
            if (lazyTarget.Length != centers.Length) lazyTarget = (PointF[])pos.Clone();
            var travel = v.PupilTravel;
            var changed = mouse != lastMouse;
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
                    if (Math.Abs(target.X - lazyTarget[i].X) + Math.Abs(target.Y - lazyTarget[i].Y) > 0.02f) changed = true;
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
                    if (Math.Abs(vel[i].X) > 0.01f || Math.Abs(vel[i].Y) > 0.01f) changed = true;
                }
                else if (pos[i] != target) { pos[i] = target; changed = true; }
            }

            var now = clock.Elapsed.TotalSeconds;
            var halfSpan = (centers[centers.Length - 1].X - centers[0].X) / 2 + (travel.Width + 6) * z;
            if (TrackCircles(mouse, mid, halfSpan, now))
            {
                v.WheelAngle = (float)wheelAngle;
                v.PupilOffsets = (PointF[])pos.Clone();
                lastMouse = mouse;
                return true;
            }
            if (v.WheelAngle.HasValue)
            {
                v.WheelAngle = null;
                for (var i = 0; i < vel.Length; i++) vel[i] = new PointF((float)(rnd.NextDouble() * 4 - 2), (float)(rnd.NextDouble() * 3 - 1.5));
                changed = true;
            }
            var closed = false;
            if (Blink)
            {
                if (nextBlink == 0) nextBlink = now + 3 + rnd.NextDouble() * 5;
                if (now >= nextBlink) { blinkUntil = now + 0.13; nextBlink = now + 3.5 + rnd.NextDouble() * 5.5; }
                closed = now < blinkUntil;
            }
            if (closed != v.EyesClosed) changed = true;
            lastMouse = mouse;
            if (changed) { v.PupilOffsets = (PointF[])pos.Clone(); v.EyesClosed = closed; }
            return changed;
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
