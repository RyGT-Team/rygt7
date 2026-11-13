// RyGT loader: the steering wheel and pedal mapping.
// It edits ryty-input.ini (the wheel lines: JOYAXIS / JOYBUTTON / JOYHAT) and ryty-wheel.ini,
// which libScePad reads, and keeps every other line of both files as it is. Live wheel state
// comes from tools\ryty-wheel-probe.exe, which reads joysticks the same way libScePad does, so
// the axis and button numbers here are the ones the game uses.
// SPDX-License-Identifier: GPL-2.0-only

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace RyGT
{
    class Wheel
    {
        /// One joystick as the probe reports it, with its latest state.
        public class Device
        {
            public int Instance;
            public string Name;
            public bool IsWheel;
            public bool Haptic;
            public int[] Axes = new int[0];
            public HashSet<int> Buttons = new HashSet<int>();
            public int[] Hats = new int[0];
            public int[] Rest = new int[0];     // the axes' resting values; empty before the probe captures them
        }

        /// One mappable control: an analog action (JOYAXIS) or a pad button (JOYBUTTON / JOYHAT).
        public class Row
        {
            public string Action, Label;
            public bool Analog;
            public string Source;        // "JOYAXIS:1", "JOYBUTTON:13", "JOYHAT:UP" or null
            public string DeviceName;    // null: the wheel
            public string OwnedLine;     // the ini line this row loaded; null: no line
            public bool Invert;
        }

        public readonly Row[] Rows =
        {
            new Row { Action = "Steering", Label = "Steering", Analog = true },
            new Row { Action = "Throttle", Label = "Throttle pedal", Analog = true },
            new Row { Action = "Brake", Label = "Brake pedal", Analog = true },
            new Row { Action = "Clutch", Label = "Clutch pedal", Analog = true },
            new Row { Action = "R1", Label = "Shift up (right paddle, R1)" },
            new Row { Action = "L1", Label = "Shift down (left paddle, L1)" },
            new Row { Action = "Cross", Label = "Cross (confirm)" },
            new Row { Action = "Circle", Label = "Circle (back)" },
            new Row { Action = "Square", Label = "Square" },
            new Row { Action = "Triangle", Label = "Triangle" },
            new Row { Action = "Options", Label = "Options (pause)" },
            new Row { Action = "Up", Label = "D-pad up" },
            new Row { Action = "Down", Label = "D-pad down" },
            new Row { Action = "Left", Label = "D-pad left" },
            new Row { Action = "Right", Label = "D-pad right" },
            new Row { Action = "L2", Label = "L2" },
            new Row { Action = "R2", Label = "R2" },
            new Row { Action = "L3", Label = "L3" },
            new Row { Action = "R3", Label = "R3" },
            new Row { Action = "RightStickUp", Label = "Right stick up" },
            new Row { Action = "RightStickRight", Label = "Right stick right" },
            new Row { Action = "RightStickDown", Label = "Right stick down" },
            new Row { Action = "RightStickLeft", Label = "Right stick left" },
            new Row { Action = "TouchLeft", Label = "Touchpad (left)" },
        };

        // The wheel models the game can be told it has (ryty-wheel.ini "Present"); the game
        // uses that model's own force feedback driver.
        public static readonly string[] PresentNames = { "Fanatec direct drive (recommended)", "Logitech G29" };
        static readonly string[] PresentIds = { "0eb7:0e05", "046d:c24f" };

        // ryty-wheel.ini's settings.
        public int Rotation = 900, Gain = 100, Damping = 10, Detail = 0, Present;
        public bool InvertForces, PadIsWheel;

        readonly string inputPath, wheelPath, probePath;
        readonly Dictionary<int, Device> devices = new Dictionary<int, Device>();
        readonly List<int> deviceOrder = new List<int>();
        /// Taken around everything that reads the devices (the probe writes them from its thread).
        public readonly object Gate = new object();
        Process probe;

        /// The input file as this window loaded it; the rows' lines come back to their places in it
        /// as long as the file is still ours (see Save).
        List<string> originalLines = new List<string>();

        /// What the last save wrote, to tell an untouched file from one that changed under us.
        List<string> lastWritten;

        /// Whether the original layout still counts; an external edit to the file turns it off for
        /// the rest of the session and Save settles for touching only the lines it recognizes.
        bool positionStable = true;

        /// Rows whose lines this window removed from the file (so mapping them again appends them back).
        readonly HashSet<Row> linesRemoved = new HashSet<Row>();

        /// The tail block the last conservative save wrote (a blank line, the marker, the rows' lines);
        /// the next save takes it back and rewrites it whole, so the block stays one tidy group no
        /// matter how many saves add or drop rows.
        List<string> appendBlock = new List<string>();

        // Detection: the row being detected, the state when it started, and when it gives up.
        Row detecting;
        Dictionary<int, int[]> baseAxes;
        Dictionary<int, HashSet<int>> baseButtons;
        Dictionary<int, int[]> baseHats;
        DateTime detectUntil;

        /// What detection says now ("Now press ...", "Steering: axis 0.").
        public string Status = "";

        public Wheel(string root)
        {
            inputPath = Path.Combine(root, "ryty-input.ini");
            wheelPath = Path.Combine(root, "ryty-wheel.ini");
            probePath = Path.Combine(root, "tools", "ryty-wheel-probe.exe");
            if (!File.Exists(probePath)) probePath = Path.Combine(root, "ryty-wheel-probe.exe");
            Load();
        }

        public Row RowOf(string action)
        {
            return Rows.FirstOrDefault(r => r.Action == action);
        }

        // ---------------------------------------------------------------- probe

        public bool Probing { get { return probe != null; } }

        public void StartProbe()
        {
            if (probe != null) return;
            if (!File.Exists(probePath))
            {
                Status = "tools\\ryty-wheel-probe.exe is missing, so the wheel cannot be detected here. " +
                         "You can still edit ryty-input.ini by hand.";
                return;
            }
            try
            {
                var info = new ProcessStartInfo(probePath, Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture))
                {
                    UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true
                };
                probe = new Process { StartInfo = info };
                probe.OutputDataReceived += (sender, e) => { if (e.Data != null) OnProbeLine(e.Data); };
                probe.Start();
                probe.BeginOutputReadLine();
                Status = "Looking for wheels...";
            }
            catch (Exception e)
            {
                probe = null;
                Status = "Could not start the wheel probe: " + e.Message;
            }
        }

        public void StopProbe()
        {
            try { if (probe != null && !probe.HasExited) probe.Kill(); } catch { }
            probe = null;
            lock (Gate)
            {
                devices.Clear();
                deviceOrder.Clear();
                detecting = null;
            }
        }

        void OnProbeLine(string line)
        {
            var parts = line.Split(new[] { ' ' }, 10);
            lock (Gate)
            {
                if (parts[0] == "devices")
                {
                    devices.Clear();
                    deviceOrder.Clear();
                }
                else if (parts[0] == "device" && parts.Length >= 9)
                {
                    // The new probe adds a haptic field (parts[5]); an old probe exe sends 9 fields.
                    var device = new Device
                    {
                        Instance = int.Parse(parts[1], CultureInfo.InvariantCulture),
                        IsWheel = parts[4] == "1",
                        Haptic = parts.Length >= 10 && parts[5] == "1",
                        Name = parts[parts.Length - 1]
                    };
                    devices[device.Instance] = device;
                    deviceOrder.Add(device.Instance);
                }
                else if (parts[0] == "state" && parts.Length >= 5)
                {
                    Device device;
                    if (!devices.TryGetValue(int.Parse(parts[1], CultureInfo.InvariantCulture), out device)) return;
                    device.Axes = parts[2] == "-" ? new int[0] : parts[2].Split(',').Select(v => int.Parse(v, CultureInfo.InvariantCulture)).ToArray();
                    device.Buttons = parts[3] == "-" ? new HashSet<int>() : new HashSet<int>(parts[3].Split(',').Select(v => int.Parse(v, CultureInfo.InvariantCulture)));
                    device.Hats = parts[4] == "-" ? new int[0] : parts[4].Split(',').Select(v => int.Parse(v, CultureInfo.InvariantCulture)).ToArray();
                    // The new probe appends the axes' resting values (parts[5]); an old probe sends five fields.
                    device.Rest = parts.Length >= 6 && parts[5] != "-" ? parts[5].Split(',').Select(v => int.Parse(v, CultureInfo.InvariantCulture)).ToArray() : new int[0];
                }
            }
        }

        // Preference rank for listing and name resolution, WheelInput::primary's order: a haptic
        // wheel first, then other wheels, then devices with axes, then the rest.
        static int Rank(Device d)
        {
            if (d.IsWheel && d.Haptic) return 0;
            if (d.IsWheel) return 1;
            if (d.Axes.Length > 0) return 2;
            return 3;
        }

        // deviceOrder with the haptic wheel first, probe order kept within a rank (take Gate).
        List<int> PriorityOrder()
        {
            return deviceOrder.Select((id, i) => new { id, i, rank = Rank(devices[id]) })
                .OrderBy(x => x.rank).ThenBy(x => x.i).Select(x => x.id).ToList();
        }

        /// The devices the probe found, the haptic wheel first (take Gate).
        public List<Device> Devices { get { return PriorityOrder().Select(id => devices[id]).ToList(); } }

        /// The device libScePad uses when a line names none: the first wheel that opens a haptic
        /// device (WheelInput::primary's order), else the first wheel, else the first device with axes.
        public Device Primary()
        {
            var order = PriorityOrder();
            foreach (var id in order) if (devices[id].IsWheel && devices[id].Haptic) return devices[id];
            foreach (var id in order) if (devices[id].IsWheel) return devices[id];
            foreach (var id in order) if (devices[id].Axes.Length > 0) return devices[id];
            return null;
        }

        Device Resolve(Row row)
        {
            if (row.DeviceName == null) return Primary();
            var wanted = row.DeviceName.ToLowerInvariant();
            foreach (var id in PriorityOrder()) if (devices[id].Name.ToLowerInvariant().Contains(wanted)) return devices[id];
            return null;
        }

        /// A row's live value, 0 to 1000 (take Gate). A direction bound to an axis shows what the
        /// game sees of it: a d-pad direction lights once its travel from rest passes a third of
        /// the range (WheelInput's threshold), and a stick direction lights with its deflection.
        public int Live(Row row)
        {
            int value = 0;
            var device = row.Source != null ? Resolve(row) : null;
            if (device != null)
            {
                var parts = row.Source.Split(':');
                int index;
                if (parts[0] == "JOYAXIS" && int.TryParse(parts[1], out index) && index < device.Axes.Length)
                {
                    int travel = device.Axes[index] - (index < device.Rest.Length ? device.Rest[index] : 0);
                    if (row.Invert) travel = -travel;
                    if (IsDpadDirection(row.Action))
                    {
                        value = travel > 10000 ? 1000 : 0;
                    }
                    else if (IsStickDirection(row.Action))
                    {
                        // The row names one end of the stick axis; travel towards the other reads as negative.
                        int deflection = row.Action == "RightStickRight" || row.Action == "RightStickDown" ? travel : -travel;
                        value = Math.Max(0, Math.Min(32767, deflection)) * 1000 / 32767;
                    }
                    else
                    {
                        value = (device.Axes[index] + 32768) * 1000 / 65535;
                        if (row.Invert) value = 1000 - value;
                    }
                }
                else if (parts[0] == "JOYBUTTON" && int.TryParse(parts[1], out index))
                {
                    value = device.Buttons.Contains(index) ? 1000 : 0;
                }
                else if (parts[0] == "JOYHAT" && device.Hats.Length > 0)
                {
                    value = (device.Hats[0] & HatBit(parts[1])) != 0 ? 1000 : 0;
                }
            }
            return Math.Max(0, Math.Min(1000, value));
        }

        /// A d-pad direction, which an axis drives past a threshold (the consumer's JOYAXIS rule).
        static bool IsDpadDirection(string action)
        {
            return action == "Up" || action == "Down" || action == "Left" || action == "Right";
        }

        /// A stick direction, which an axis drives proportionally across the whole range.
        static bool IsStickDirection(string action)
        {
            return action == "RightStickUp" || action == "RightStickDown" || action == "RightStickLeft" || action == "RightStickRight";
        }

        /// What the probe reads right now, one line per device, the haptic wheel first (take Gate).
        public string RawInput()
        {
            return string.Join(Environment.NewLine, PriorityOrder().Select(id =>
            {
                var d = devices[id];
                return d.Name + (d.Haptic ? " (haptic)" : "") + ": axes " + string.Join(" ", d.Axes.Select((v, i) => i + ":" + (v * 100 / 32768).ToString(CultureInfo.InvariantCulture) + "%")) +
                       "   buttons " + (d.Buttons.Count == 0 ? "none" : string.Join(",", d.Buttons.OrderBy(b => b))) +
                       (d.Hats.Length > 0 && d.Hats[0] != 0 ? "   hat " + d.Hats[0] : "");
            }).ToArray());
        }

        // ---------------------------------------------------------------- detection

        public Row Detecting { get { return detecting; } }

        public int SecondsLeft { get { return detecting == null ? 0 : Math.Max(0, (int)Math.Ceiling((detectUntil - DateTime.Now).TotalSeconds)); } }

        public void StartDetect(Row row)
        {
            lock (Gate)
            {
                if (deviceOrder.Count == 0)
                {
                    Status = "No wheel found yet.";
                    return;
                }
                detecting = row;
                baseAxes = deviceOrder.ToDictionary(id => id, id => (int[])devices[id].Axes.Clone());
                baseButtons = deviceOrder.ToDictionary(id => id, id => new HashSet<int>(devices[id].Buttons));
                baseHats = deviceOrder.ToDictionary(id => id, id => (int[])devices[id].Hats.Clone());
                detectUntil = DateTime.Now.AddSeconds(10);
                Status = row.Analog
                    ? "Now " + (row.Action == "Steering" ? "turn the wheel well to the right" : "press the " + row.Label.ToLowerInvariant() + " all the way") + "."
                    : "Now press the button, move the stick or press the hat for " + row.Label + ".";
            }
        }

        public void CancelDetect()
        {
            lock (Gate)
            {
                if (detecting == null) return;
                detecting = null;
                Status = "";
            }
        }

        /// Looks for the input being detected; true when it found one (or gave up). Take Gate.
        public bool StepDetect()
        {
            if (detecting == null) return false;
            if (DateTime.Now > detectUntil)
            {
                Status = "Nothing detected for " + detecting.Label + ".";
                detecting = null;
                return true;
            }
            foreach (var id in deviceOrder)
            {
                var device = devices[id];
                int[] start;
                if (!baseAxes.TryGetValue(id, out start)) continue;
                if (detecting.Analog)
                {
                    for (int axis = 0; axis < Math.Min(start.Length, device.Axes.Length); ++axis)
                    {
                        int moved = device.Axes[axis] - start[axis];
                        if (Math.Abs(moved) < 20000) continue;
                        var row = detecting;
                        Assign(device, "JOYAXIS:" + axis);
                        // Steering was turned right: if that lowered the axis, the game needs it reversed.
                        if (row.Action == "Steering" && moved < 0) row.Invert = true;
                        return true;
                    }
                }
                else
                {
                    foreach (var button in device.Buttons)
                    {
                        if (baseButtons[id].Contains(button)) continue;
                        Assign(device, "JOYBUTTON:" + button);
                        return true;
                    }
                    // A d-pad or stick direction can also be an axis; the consumer rejects an axis
                    // on any other row, so button rows keep looking for buttons and hats only.
                    if (IsDpadDirection(detecting.Action) || IsStickDirection(detecting.Action))
                    {
                        for (int axis = 0; axis < Math.Min(start.Length, device.Axes.Length); ++axis)
                        {
                            if (device == Primary() && axis == 0) continue;   // the steering wheel axis
                            if (Math.Abs(start[axis]) > 30000) continue;       // a pedal: rests at a range end
                            int moved = device.Axes[axis] - start[axis];
                            if (Math.Abs(moved) < 20000) continue;
                            var row = detecting;
                            Assign(device, "JOYAXIS:" + axis);
                            row.Invert = moved < 0;   // Assign clears it; the direction's row names one end of the axis
                            return true;
                        }
                    }
                    var hats = baseHats[id];
                    for (int hat = 0; hat < Math.Min(1, device.Hats.Length); ++hat)
                    {
                        int pressed = device.Hats[hat] & ~(hat < hats.Length ? hats[hat] : 0);
                        foreach (var direction in new[] { "UP", "RIGHT", "DOWN", "LEFT" })
                        {
                            if ((pressed & HatBit(direction)) == 0) continue;
                            Assign(device, "JOYHAT:" + direction);
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        void Assign(Device device, string source)
        {
            var row = detecting;
            detecting = null;
            row.Source = source;
            var primary = Primary();
            row.DeviceName = primary != null && primary.Instance == device.Instance ? null : device.Name;
            row.Invert = false;
            Status = row.Label + ": " + Describe(row) + ".";
        }

        static int HatBit(string direction)
        {
            switch (direction.ToUpperInvariant())
            {
                case "UP": return 1;
                case "RIGHT": return 2;
                case "DOWN": return 4;
                case "LEFT": return 8;
            }
            return 0;
        }

        /// "axis 0", "button 13 on Fanatec ...", "hat up" or "(not mapped)".
        public static string Describe(Row row)
        {
            if (row.Source == null) return "(not mapped)";
            var text = Short(row);
            if (row.Invert && row.Source.StartsWith("JOYAXIS")) text += " (inverted)";
            if (row.DeviceName != null) text += " on " + row.DeviceName;
            return text;
        }

        /// "Axis 0", "Button 13", "Hat up" or "None".
        public static string Short(Row row)
        {
            if (row.Source == null) return "None";
            var parts = row.Source.Split(':');
            if (parts[0] == "JOYAXIS") return "Axis " + parts[1];
            if (parts[0] == "JOYBUTTON") return "Button " + parts[1];
            return "Hat " + parts[1].ToLowerInvariant();
        }

        // ---------------------------------------------------------------- files

        static string ActionOf(string line, out string source)
        {
            source = null;
            var text = line;
            int comment = text.IndexOfAny(new[] { '#', ';' });
            if (comment >= 0) text = text.Substring(0, comment);
            int eq = text.IndexOf('=');
            if (eq <= 0) return null;
            source = text.Substring(eq + 1).Trim();
            return text.Substring(0, eq).Trim();
        }

        static bool IsJoystickSource(string source)
        {
            if (source == null) return false;
            var upper = source.ToUpperInvariant();
            return upper.StartsWith("JOYAXIS:") || upper.StartsWith("JOYBUTTON:") || upper.StartsWith("JOYHAT:");
        }

        void Load()
        {
            var lines = File.Exists(inputPath) ? File.ReadAllLines(inputPath).ToList() : new List<string>();
            originalLines = lines;
            if (lines.Count > 0)
            {
                foreach (var line in lines)
                {
                    string source;
                    var action = ActionOf(line, out source);
                    if (action == null || !IsJoystickSource(source)) continue;
                    var row = Rows.FirstOrDefault(r => string.Equals(r.Action, action, StringComparison.OrdinalIgnoreCase));
                    if (row == null || row.Source != null) continue;
                    string device = null;
                    int at = source.IndexOf('@');
                    if (at >= 0) { device = source.Substring(at + 1).Trim(); source = source.Substring(0, at).Trim(); }
                    var parts = source.Split(':');
                    row.Source = parts[0].Trim().ToUpperInvariant() + ":" + parts[1].Trim().ToUpperInvariant();
                    row.Invert = parts.Length > 2 && parts[2].Trim().ToUpperInvariant() == "INVERT";
                    row.DeviceName = device;
                    row.OwnedLine = line;
                }
            }
            var settings = ReadWheelSettings();
            int value;
            string text;
            if (settings.TryGetValue("rotation", out text) && int.TryParse(text, out value)) Rotation = Math.Max(90, Math.Min(2880, value));
            if (settings.TryGetValue("ffbgain", out text) && int.TryParse(text, out value)) Gain = Math.Max(0, Math.Min(200, value));
            if (settings.TryGetValue("ffbinvert", out text)) InvertForces = text == "1";
            if (settings.TryGetValue("ffbdamping", out text) && int.TryParse(text, out value)) Damping = Math.Max(0, Math.Min(100, value));
            if (settings.TryGetValue("ffbdetail", out text) && int.TryParse(text, out value)) Detail = Math.Max(0, Math.Min(200, value));
            if (settings.TryGetValue("padiswheel", out text)) PadIsWheel = text == "1";
            if (settings.TryGetValue("present", out text))
            {
                int index = Array.FindIndex(PresentIds, id => string.Equals(id, text.Trim(), StringComparison.OrdinalIgnoreCase));
                if (index < 0 && text.Trim().StartsWith("0eb7", StringComparison.OrdinalIgnoreCase)) index = 0;
                if (index >= 0) Present = index;
            }
        }

        Dictionary<string, string> ReadWheelSettings()
        {
            var result = new Dictionary<string, string>();
            if (!File.Exists(wheelPath)) return result;
            foreach (var line in File.ReadAllLines(wheelPath))
            {
                string value;
                var key = ActionOf(line, out value);
                if (key != null) result[key.ToLowerInvariant()] = value;
            }
            return result;
        }

        /// The ini line a row's current state writes as.
        static string LineOf(Row row)
        {
            var line = row.Action + " = " + row.Source;
            if (row.Invert && row.Source.StartsWith("JOYAXIS")) line += ":INVERT";
            if (row.DeviceName != null) line += " @ " + row.DeviceName;
            return line;
        }

        public void Save()
        {
            // ryty-input.ini. While the file is still ours, the rows' lines keep their original
            // places: a cleared row is dropped, a re-mapped one comes back in its spot, rows that
            // never had a line collect in one tail block, and every other line - unknown actions,
            // extra bindings for the same action - stays as it is. If the file changed under us,
            // we settle for touching only the lines we recognize, and stay there for the session.
            var inputLines = File.Exists(inputPath) ? File.ReadAllLines(inputPath).ToList() : new List<string>();
            if (positionStable && inputLines.SequenceEqual(lastWritten ?? originalLines))
            {
                var kept = new List<string>();
                var placed = new HashSet<Row>();
                foreach (var line in originalLines)
                {
                    string source;
                    var action = ActionOf(line, out source);
                    var row = action == null ? null : Rows.FirstOrDefault(r => string.Equals(r.Action, action, StringComparison.OrdinalIgnoreCase));
                    if (row != null && line == row.OwnedLine)
                    {
                        placed.Add(row);
                        if (row.Source != null) kept.Add(LineOf(row));   // a cleared row drops its line
                    }
                    else kept.Add(line);
                }
                var added = new List<string>();
                foreach (var row in Rows)
                {
                    if (row.Source != null && !placed.Contains(row)) added.Add(LineOf(row));
                }
                if (added.Count > 0)
                {
                    while (kept.Count > 0 && kept[kept.Count - 1].Trim().Length == 0) kept.RemoveAt(kept.Count - 1);
                    if (kept.Count > 0) kept.Add("");
                    kept.Add("# Racing wheel (written by the RyGT launcher)");
                    kept.AddRange(added);
                }
                lastWritten = kept;
                File.WriteAllLines(inputPath, kept, new UTF8Encoding(false));
            }
            else
            {
                positionStable = false;
                // Conservative: the file changed under us. Rewrite only the lines we recognize, never
                // add a line for an action the file already has, and keep the tail block tidy.
                // Take back the tail block the last conservative save wrote (still at the end,
                // possibly followed by a trailing blank) so it can be rewritten whole.
                if (appendBlock.Count > 0)
            {
                int skip = 0;
                while (skip < inputLines.Count && inputLines[inputLines.Count - 1 - skip].Trim().Length == 0) ++skip;
                int start = inputLines.Count - skip - appendBlock.Count;
                if (start >= 0 && inputLines.GetRange(start, appendBlock.Count).SequenceEqual(appendBlock))
                {
                    foreach (var line in appendBlock)
                    {
                        var row = Rows.FirstOrDefault(r => r.OwnedLine == line);
                        if (row != null) linesRemoved.Add(row);
                    }
                    inputLines.RemoveRange(start, appendBlock.Count + skip);
                }
            }
            var owned = new HashSet<Row>();
            for (int i = 0; i < inputLines.Count; ++i)
            {
                string source;
                var action = ActionOf(inputLines[i], out source);
                var row = action == null ? null : Rows.FirstOrDefault(r => string.Equals(r.Action, action, StringComparison.OrdinalIgnoreCase));
                if (row != null && row.OwnedLine != null && !owned.Contains(row) && inputLines[i] == row.OwnedLine)
                {
                    owned.Add(row);
                    if (row.Source == null)
                    {
                        inputLines.RemoveAt(i);
                        linesRemoved.Add(row);
                    }
                    else
                    {
                        inputLines[i] = LineOf(row);
                        row.OwnedLine = inputLines[i];   // remember the new line for the next save
                        linesRemoved.Remove(row);
                    }
                }
            }
            // Actions that already have a line in the file (for rows that never had one of their own:
            // a line added by hand after the window opened is kept, not duplicated).
            var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in inputLines)
            {
                string source;
                var action = ActionOf(line, out source);
                if (action != null) present.Add(action);
            }
            var toAppend = new List<Row>();
            foreach (var row in Rows)
            {
                // A row appends a line only if it never had one (newly mapped) or this window removed
                // its line (cleared, then mapped again). If its line is missing for any other reason,
                // the file changed under us (edited externally, or this window loaded an older
                // version of it) - the line that is there stays, and no second line is added.
                if (row.Source == null || owned.Contains(row)) continue;
                if (row.OwnedLine != null && !linesRemoved.Contains(row)) continue;
                if (row.OwnedLine == null && present.Contains(row.Action)) continue;
                toAppend.Add(row);
            }
            // The new tail block: a blank line, the marker, the lines. Rebuilt whole, so the file
            // never accumulates blank lines or markers between saves.
            var block = new List<string>();
            if (toAppend.Count > 0)
            {
                while (inputLines.Count > 0 && inputLines[inputLines.Count - 1].Trim().Length == 0) inputLines.RemoveAt(inputLines.Count - 1);
                if (inputLines.Count > 0) block.Add("");
                block.Add("# Racing wheel (written by the RyGT launcher)");
                foreach (var row in toAppend)
                {
                    var line = LineOf(row);
                    block.Add(line);
                    row.OwnedLine = line;   // the next save finds it here
                    linesRemoved.Remove(row);
                }
            }
                appendBlock = block;
                inputLines.AddRange(block);
                lastWritten = inputLines;
                File.WriteAllLines(inputPath, inputLines, new UTF8Encoding(false));
            }

            // ryty-wheel.ini: the settings edited here are replaced in place; others stay.
            var values = new Dictionary<string, string>
            {
                { "Rotation", Rotation.ToString(CultureInfo.InvariantCulture) },
                { "FfbGain", Gain.ToString(CultureInfo.InvariantCulture) },
                { "FfbInvert", InvertForces ? "1" : "0" },
                { "FfbDamping", Damping.ToString(CultureInfo.InvariantCulture) },
                { "FfbDetail", Detail.ToString(CultureInfo.InvariantCulture) },
                { "PadIsWheel", PadIsWheel ? "1" : "0" },
                { "Present", PresentIds[Math.Max(0, Math.Min(PresentIds.Length - 1, Present))] },
            };
            var lines = File.Exists(wheelPath) ? File.ReadAllLines(wheelPath).ToList() : new List<string> { "# Racing wheel settings for RyGT (also editable in the launcher)." };
            var written = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < lines.Count; ++i)
            {
                string value;
                var key = ActionOf(lines[i], out value);
                if (key == null) continue;
                var match = values.Keys.FirstOrDefault(k => string.Equals(k, key, StringComparison.OrdinalIgnoreCase));
                if (match == null) continue;
                lines[i] = match + " = " + values[match];
                written.Add(match);
            }
            foreach (var pair in values) if (!written.Contains(pair.Key)) lines.Add(pair.Key + " = " + pair.Value);
            File.WriteAllLines(wheelPath, lines, new UTF8Encoding(false));
        }
    }
}
