using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;
using MediaColor = System.Windows.Media.Color;

namespace MausIsland
{
    internal static class Program
    {
        private static Mutex _mutex;
        internal static bool Debug;
        internal static bool Demo;

        [STAThread]
        private static void Main(string[] args)
        {
            bool created;
            _mutex = new Mutex(true, "MausIsland_SingleInstance_v1", out created);
            if (!created) return;

            Debug = Array.IndexOf(args, "--debug") >= 0;
            Demo = Array.IndexOf(args, "--hover-demo") >= 0;
            bool preview = Array.IndexOf(args, "--preview") >= 0;
            var app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var ctx = new IslandApp(preview);
            app.Run();
        }
    }

    internal sealed class IslandApp
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "MausIsland";

        private readonly IslandWindow _island;
        private readonly DispatcherTimer _watch;
        private readonly System.Windows.Forms.NotifyIcon _tray;
        private readonly bool _preview;
        private DateTime _previewUntil;
        private IntPtr _target;

        public IslandApp(bool preview)
        {
            _preview = preview;
            if (preview) _previewUntil = DateTime.UtcNow.AddSeconds(300);

            _island = new IslandWindow();
            _island.RestoreRequested += delegate { RestoreTarget(); };
            _island.ExitRequested += delegate { Shutdown(); };
            if (Program.Demo) _island.StartHoverDemo();

            var menu = new System.Windows.Forms.ContextMenuStrip();
            var open = new System.Windows.Forms.ToolStripMenuItem("Open MausBot");
            open.Click += delegate { RestoreTarget(); };
            var hide = new System.Windows.Forms.ToolStripMenuItem("Hide island");
            hide.Click += delegate { _island.HideIsland(); };
            var startup = new System.Windows.Forms.ToolStripMenuItem("Start with Windows");
            startup.CheckOnClick = true;
            startup.Checked = IsStartupEnabled();
            startup.CheckedChanged += delegate { SetStartup(startup.Checked); };
            var exit = new System.Windows.Forms.ToolStripMenuItem("Exit");
            exit.Click += delegate { Shutdown(); };

            menu.Items.Add(open);
            menu.Items.Add(hide);
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add(startup);
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add(exit);

            _tray = new System.Windows.Forms.NotifyIcon();
            _tray.Icon = LoadAppIcon();
            _tray.Text = "MausBot island";
            _tray.Visible = true;
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += delegate { RestoreTarget(); };

            _watch = new DispatcherTimer();
            _watch.Interval = TimeSpan.FromMilliseconds(120);
            _watch.Tick += delegate { Watch(); };
            _watch.Start();
            Watch();
        }

        private void Watch()
        {
            IntPtr hwnd = FindMausWindow();
            _target = hwnd;

            bool minimized = hwnd != IntPtr.Zero && Native.IsIconic(hwnd) && Native.IsWindowVisible(hwnd);
            bool force = _preview && DateTime.UtcNow < _previewUntil;

            if (minimized || force)
            {
                if (!_island.IsVisible) _island.ShowIsland(hwnd);
            }
            else
            {
                if (_island.IsVisible) _island.HideIsland();
            }
        }

        private void RestoreTarget()
        {
            IntPtr hwnd = _target;
            if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd))
                hwnd = FindMausWindow();

            if (hwnd != IntPtr.Zero)
            {
                Native.ShowWindow(hwnd, Native.SW_RESTORE);
                Native.SetForegroundWindow(hwnd);
            }
        }

        private static IntPtr FindMausWindow()
        {
            var pids = new HashSet<uint>();
            Process[] procs = Process.GetProcessesByName("OpenMausBot");
            for (int i = 0; i < procs.Length; i++)
            {
                try { pids.Add((uint)procs[i].Id); }
                catch { }
                procs[i].Dispose();
            }
            if (pids.Count == 0) return IntPtr.Zero;

            IntPtr found = IntPtr.Zero;
            Native.EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint pid;
                Native.GetWindowThreadProcessId(h, out pid);
                if (!pids.Contains(pid)) return true;
                if (!Native.IsWindowVisible(h)) return true;
                if (Native.GetWindow(h, Native.GW_OWNER) != IntPtr.Zero) return true;

                var sb = new StringBuilder(256);
                Native.GetWindowText(h, sb, sb.Capacity);
                if (sb.ToString().IndexOf("MausBot", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    found = h;
                    return false;
                }
                return true;
            }, IntPtr.Zero);

            return found;
        }

        private static System.Drawing.Icon LoadAppIcon()
        {
            try
            {
                string exe = @"C:\Users\Admin\AppData\Local\Programs\openmausbot\OpenMausBot.exe";
                if (System.IO.File.Exists(exe))
                    return System.Drawing.Icon.ExtractAssociatedIcon(exe);
            }
            catch { }
            return System.Drawing.SystemIcons.Application;
        }

        private static bool IsStartupEnabled()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
                {
                    return k != null && k.GetValue(RunValue) != null;
                }
            }
            catch { return false; }
        }

        private static void SetStartup(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null) return;
                    if (on)
                    {
                        string exe = Process.GetCurrentProcess().MainModule.FileName;
                        k.SetValue(RunValue, "\"" + exe + "\"");
                    }
                    else
                    {
                        k.DeleteValue(RunValue, false);
                    }
                }
            }
            catch { }
        }

        private void Shutdown()
        {
            try { _tray.Visible = false; _tray.Dispose(); } catch { }
            try { _island.Close(); } catch { }
            System.Windows.Application.Current.Shutdown();
        }
    }

    /// <summary>
    /// Mac-style faux notch: a black tab hanging from the top edge of the screen,
    /// with side "ears" on hover and a tiny face whose eyes follow the cursor.
    /// </summary>
    internal sealed class IslandWindow : Window
    {
        private const double CollapsedW = 250;
        private const double CollapsedH = 38;
        private const double ExpandedW = 360;
        private const double ExpandedH = 54;
        private const double EarW = 20;
        private const double EarH = 14;

        private readonly Border _notch;
        private readonly Border _earL;
        private readonly Border _earR;
        private readonly TextBlock _subtitle;
        private readonly ScaleTransform _press = new ScaleTransform(1, 1);
        private readonly ScaleTransform _blink = new ScaleTransform(1, 1);
        private readonly TranslateTransform _pupilL = new TranslateTransform();
        private readonly TranslateTransform _pupilR = new TranslateTransform();
        private readonly Grid _eyeL;
        private readonly Grid _eyeR;

        private readonly double _padding = 16;
        private static readonly Random Rnd = new Random();

        private double _w = CollapsedW;
        private double _h = CollapsedH;
        private bool _expanded;
        private bool _restoring;
        private bool _hiding;
        private DateTime _settleFrom;
        private IntPtr _hwnd;
        private double _scale = 1.0;
        private bool _demo;
        private DateTime _nextBlink = DateTime.UtcNow.AddSeconds(4);

        public event EventHandler RestoreRequested;
        public event EventHandler ExitRequested;

        public IslandWindow()
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = null;                 // transparent areas stay click-through
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            SnapsToDevicePixels = true;
            UseLayoutRounding = true;
            Title = "MausIsland";

            // ---- shape -------------------------------------------------------
            _earL = new Border();
            _earL.Width = EarW;
            _earL.Height = EarH;
            _earL.Background = new SolidColorBrush(MediaColor.FromRgb(5, 5, 7));
            _earL.CornerRadius = new CornerRadius(0, 0, 0, 11);
            _earL.HorizontalAlignment = HorizontalAlignment.Left;
            _earL.VerticalAlignment = VerticalAlignment.Top;
            _earL.Opacity = 0;
            _earL.IsHitTestVisible = false;

            _earR = new Border();
            _earR.Width = EarW;
            _earR.Height = EarH;
            _earR.Background = new SolidColorBrush(MediaColor.FromRgb(5, 5, 7));
            _earR.CornerRadius = new CornerRadius(0, 0, 11, 0);
            _earR.HorizontalAlignment = HorizontalAlignment.Right;
            _earR.VerticalAlignment = VerticalAlignment.Top;
            _earR.Opacity = 0;
            _earR.IsHitTestVisible = false;

            _notch = new Border();
            _notch.Background = new SolidColorBrush(MediaColor.FromRgb(5, 5, 7));
            _notch.BorderBrush = new SolidColorBrush(MediaColor.FromRgb(26, 26, 32));
            _notch.BorderThickness = new Thickness(0, 0, 1, 1);
            _notch.CornerRadius = new CornerRadius(0, 0, CollapsedH / 2, CollapsedH / 2);
            _notch.HorizontalAlignment = HorizontalAlignment.Center;
            _notch.VerticalAlignment = VerticalAlignment.Top;
            _notch.RenderTransformOrigin = new System.Windows.Point(0.5, 0);
            _notch.RenderTransform = _press;
            _notch.Effect = new DropShadowEffect
            {
                BlurRadius = 26,
                ShadowDepth = 7,
                Direction = 270,
                Opacity = 0.55,
                Color = Colors.Black
            };

            // ---- content -----------------------------------------------------
            var root = new Grid();
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_padding) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_padding) });

            var iconWrap = new Grid();
            iconWrap.Width = 22;
            iconWrap.Height = 22;
            iconWrap.VerticalAlignment = VerticalAlignment.Center;

            ImageSource iconSource = LoadMausIcon();
            if (iconSource != null)
            {
                var img = new System.Windows.Controls.Image();
                img.Source = iconSource;
                img.Width = 22;
                img.Height = 22;
                img.Stretch = Stretch.Uniform;
                iconWrap.Children.Add(img);
            }
            else
            {
                var fallback = new Ellipse();
                fallback.Width = 16;
                fallback.Height = 16;
                fallback.Fill = new SolidColorBrush(MediaColor.FromRgb(235, 235, 240));
                iconWrap.Children.Add(fallback);
            }

            var dot = new Ellipse();
            dot.Width = 8;
            dot.Height = 8;
            dot.Fill = new SolidColorBrush(MediaColor.FromRgb(48, 209, 88));
            dot.Stroke = new SolidColorBrush(MediaColor.FromRgb(5, 5, 7));
            dot.StrokeThickness = 2;
            dot.HorizontalAlignment = HorizontalAlignment.Right;
            dot.VerticalAlignment = VerticalAlignment.Bottom;
            dot.Margin = new Thickness(0, 0, -2, -2);
            iconWrap.Children.Add(dot);

            var dotPulse = new DoubleAnimation();
            dotPulse.From = 1.0;
            dotPulse.To = 0.5;
            dotPulse.Duration = TimeSpan.FromMilliseconds(1400);
            dotPulse.AutoReverse = true;
            dotPulse.RepeatBehavior = RepeatBehavior.Forever;
            dot.BeginAnimation(OpacityProperty, dotPulse);

            Grid.SetColumn(iconWrap, 1);
            root.Children.Add(iconWrap);

            var title = new TextBlock();
            title.Text = "MausBot";
            title.FontFamily = new System.Windows.Media.FontFamily("Segoe UI Semibold");
            title.FontSize = 13;
            title.Foreground = new SolidColorBrush(MediaColor.FromRgb(245, 245, 247));
            title.VerticalAlignment = VerticalAlignment.Center;

            _subtitle = new TextBlock();
            _subtitle.Text = "minimized \u00B7 click to open";
            _subtitle.FontFamily = new System.Windows.Media.FontFamily("Segoe UI");
            _subtitle.FontSize = 10.5;
            _subtitle.Foreground = new SolidColorBrush(MediaColor.FromRgb(150, 150, 162));
            _subtitle.Margin = new Thickness(0, 2, 0, 0);
            _subtitle.Visibility = Visibility.Collapsed;

            var stack = new StackPanel();
            stack.VerticalAlignment = VerticalAlignment.Center;
            stack.Children.Add(title);
            stack.Children.Add(_subtitle);

            Grid.SetColumn(stack, 3);
            root.Children.Add(stack);

            // ---- face: two eyes, pupils follow the cursor --------------------
            var face = new StackPanel();
            face.Orientation = Orientation.Horizontal;
            face.VerticalAlignment = VerticalAlignment.Center;
            face.HorizontalAlignment = HorizontalAlignment.Right;
            face.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
            face.RenderTransform = _blink;

            _eyeL = MakeEye(_pupilL);
            _eyeR = MakeEye(_pupilR);
            var gap = new Border();
            gap.Width = 4;
            face.Children.Add(_eyeL);
            face.Children.Add(gap);
            face.Children.Add(_eyeR);

            Grid.SetColumn(face, 5);
            root.Children.Add(face);

            _notch.Child = root;

            var host = new StackPanel();
            host.Orientation = Orientation.Horizontal;
            host.HorizontalAlignment = HorizontalAlignment.Center;
            host.VerticalAlignment = VerticalAlignment.Top;
            host.Children.Add(_earL);
            host.Children.Add(_notch);
            host.Children.Add(_earR);
            Content = host;

            // The window itself stays at full size; only the notch is animated.
            // Resizing the native window every frame was what made it feel slow.
            Width = ExpandedW + EarW * 2;
            Height = ExpandedH;

            MouseLeftButtonUp += delegate { RestoreWithDab(); };
            MouseRightButtonUp += delegate
            {
                if (ContextMenu != null)
                {
                    ContextMenu.PlacementTarget = this;
                    ContextMenu.IsOpen = true;
                }
            };
            SourceInitialized += OnSourceInitialized;

            var cm = new ContextMenu();
            var miOpen = new MenuItem();
            miOpen.Header = "Open MausBot";
            miOpen.Click += delegate
            {
                if (RestoreRequested != null) RestoreRequested(this, EventArgs.Empty);
            };
            var miExit = new MenuItem();
            miExit.Header = "Exit island";
            miExit.Click += delegate
            {
                if (ExitRequested != null) ExitRequested(this, EventArgs.Empty);
            };
            cm.Items.Add(miOpen);
            cm.Items.Add(miExit);
            ContextMenu = cm;

            var track = new DispatcherTimer();
            track.Interval = TimeSpan.FromMilliseconds(16);
            track.Tick += delegate { TrackCursor(); Blink(); };
            track.Start();

            if (Program.Debug)
            {
                var log = new DispatcherTimer();
                log.Interval = TimeSpan.FromMilliseconds(1000);
                log.Tick += delegate
                {
                    try
                    {
                        System.IO.File.AppendAllText(
                            System.IO.Path.Combine(System.IO.Path.GetTempPath(), "mausisland.log"),
                            string.Format("{0:HH:mm:ss} w={1:F1} h={2:F1} actual={3:F1}x{4:F1} left={5:F1} top={6:F1} scale={7:F3} exp={8}\r\n",
                                DateTime.Now, _w, _h, ActualWidth, ActualHeight, Left, Top, _scale, _expanded));
                    }
                    catch { }
                };
                log.Start();
            }
        }

        private static Grid MakeEye(TranslateTransform pupilShift)
        {
            var eye = new Grid();
            eye.Width = 7;
            eye.Height = 9;

            var white = new Ellipse();
            white.Fill = new SolidColorBrush(MediaColor.FromRgb(242, 242, 247));
            eye.Children.Add(white);

            var pupil = new Ellipse();
            pupil.Width = 3.2;
            pupil.Height = 3.2;
            pupil.Fill = new SolidColorBrush(MediaColor.FromRgb(10, 10, 14));
            pupil.HorizontalAlignment = HorizontalAlignment.Center;
            pupil.VerticalAlignment = VerticalAlignment.Center;
            pupil.RenderTransform = pupilShift;
            eye.Children.Add(pupil);

            return eye;
        }

        private static ImageSource LoadMausIcon()
        {
            try
            {
                string p = @"C:\Users\Admin\AppData\Local\Programs\openmausbot\resources\ui\app-icon-192.png";
                if (!System.IO.File.Exists(p)) return null;
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.UriSource = new Uri(p, UriKind.Absolute);
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.EndInit();
                bmp.Freeze();
                return bmp;
            }
            catch { return null; }
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            int ex = Native.GetWindowLong(handle, Native.GWL_EXSTYLE);
            Native.SetWindowLong(handle, Native.GWL_EXSTYLE, ex | Native.WS_EX_TOOLWINDOW);
        }

        public void ShowIsland(IntPtr hwnd)
        {
            _hwnd = hwnd;
            if (IsVisible) return;

            _expanded = false;
            _restoring = false;
            _hiding = false;
            _w = CollapsedW;
            _h = CollapsedH;
            _subtitle.Visibility = Visibility.Collapsed;
            _subtitle.Opacity = 0;

            _notch.BeginAnimation(WidthProperty, null);
            _notch.BeginAnimation(HeightProperty, null);
            _notch.Width = CollapsedW;
            _notch.Height = CollapsedH;
            _notch.CornerRadius = new CornerRadius(0, 0, CollapsedH / 2, CollapsedH / 2);

            // Quick pop: starts slightly small and springs to full size.
            _press.ScaleX = 0.88;
            _press.ScaleY = 0.88;
            var pop = new BackEase();
            pop.Amplitude = 0.35;
            pop.EasingMode = EasingMode.EaseOut;
            var popX = new DoubleAnimation(1, TimeSpan.FromMilliseconds(230));
            popX.EasingFunction = pop;
            _press.BeginAnimation(ScaleTransform.ScaleXProperty, popX);
            var popY = new DoubleAnimation(1, TimeSpan.FromMilliseconds(230));
            popY.EasingFunction = pop;
            _press.BeginAnimation(ScaleTransform.ScaleYProperty, popY);

            Place();
            Opacity = 0;
            Show();
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(70)));
        }

        public void HideIsland()
        {
            if (!IsVisible || _hiding) return;
            _hiding = true;
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(110));
            fade.Completed += delegate
            {
                _hiding = false;
                Hide();
                Opacity = 1;
            };
            BeginAnimation(OpacityProperty, fade);
        }

        private void SetExpanded(bool expanded)
        {
            if (_expanded == expanded) return;
            _expanded = expanded;
            _w = expanded ? ExpandedW : CollapsedW;
            _h = expanded ? ExpandedH : CollapsedH;
            _settleFrom = DateTime.UtcNow;

            // Eased, fixed-duration size change: 160 ms out, 120 ms back.
            // Only the notch is resized, so this runs at full frame rate.
            var ease = new BackEase();
            ease.Amplitude = expanded ? 0.55 : 0.0;
            ease.EasingMode = EasingMode.EaseOut;

            var dw = new DoubleAnimation(_w, TimeSpan.FromMilliseconds(expanded ? 160 : 120));
            dw.EasingFunction = ease;
            var dh = new DoubleAnimation(_h, TimeSpan.FromMilliseconds(expanded ? 160 : 120));
            dh.EasingFunction = ease;
            dh.Completed += delegate
            {
                _notch.CornerRadius = new CornerRadius(0, 0, _h / 2, _h / 2);
                if (Program.Debug)
                {
                    try
                    {
                        System.IO.File.AppendAllText(
                            System.IO.Path.Combine(System.IO.Path.GetTempPath(), "mausisland.log"),
                            string.Format("{0:HH:mm:ss.fff} settled {1} in {2:F0} ms\r\n",
                                DateTime.Now, _expanded ? "open" : "close",
                                (DateTime.UtcNow - _settleFrom).TotalMilliseconds));
                    }
                    catch { }
                }
            };

            _notch.BeginAnimation(WidthProperty, dw);
            _notch.BeginAnimation(HeightProperty, dh);

            _earL.BeginAnimation(OpacityProperty,
                new DoubleAnimation(expanded ? 1 : 0, TimeSpan.FromMilliseconds(expanded ? 110 : 80)));
            _earR.BeginAnimation(OpacityProperty,
                new DoubleAnimation(expanded ? 1 : 0, TimeSpan.FromMilliseconds(expanded ? 110 : 80)));

            if (expanded)
            {
                _subtitle.Visibility = Visibility.Visible;
                _subtitle.BeginAnimation(OpacityProperty,
                    new DoubleAnimation(1, TimeSpan.FromMilliseconds(90)));
            }
            else
            {
                _subtitle.BeginAnimation(OpacityProperty,
                    new DoubleAnimation(0, TimeSpan.FromMilliseconds(60)));
                var t = new DispatcherTimer();
                t.Interval = TimeSpan.FromMilliseconds(70);
                t.Tick += delegate
                {
                    t.Stop();
                    if (!_expanded) _subtitle.Visibility = Visibility.Collapsed;
                };
                t.Start();
            }
        }

        private void RestoreWithDab()
        {
            if (_restoring) return;
            _restoring = true;

            var dab = new DoubleAnimationUsingKeyFrames();
            dab.Duration = TimeSpan.FromMilliseconds(120);
            dab.KeyFrames.Add(new EasingDoubleKeyFrame(0.95, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(40))));
            dab.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(120))));
            _press.BeginAnimation(ScaleTransform.ScaleXProperty, dab);
            _press.BeginAnimation(ScaleTransform.ScaleYProperty, dab);

            var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(110));
            fade.BeginTime = TimeSpan.FromMilliseconds(60);
            fade.Completed += delegate
            {
                _restoring = false;
                _press.ScaleX = 1;
                _press.ScaleY = 1;
                Opacity = 1;
                Hide();
                if (RestoreRequested != null) RestoreRequested(this, EventArgs.Empty);
            };
            BeginAnimation(OpacityProperty, fade);
        }

        public void StartHoverDemo()
        {
            _demo = true;
            var toggle = new DispatcherTimer();
            toggle.Interval = TimeSpan.FromMilliseconds(1400);
            toggle.Tick += delegate { SetExpanded(!_expanded); };
            toggle.Start();
        }

        private void TrackCursor()
        {
            if (!IsVisible) return;

            Native.POINT p;
            if (!Native.GetCursorPos(out p)) return;

            double mx = p.X / _scale;
            double my = p.Y / _scale;

            // Polled hover with hysteresis: expand just below the notch,
            // collapse only once the pointer is clearly away. No enter/leave flicker.
            double margin = _expanded ? 26 : 6;
            double halfW = (_expanded ? ExpandedW : CollapsedW) / 2.0;
            double cx = Left + Width / 2.0;      // notch is always window-centred
            bool inside = Math.Abs(mx - cx) <= halfW + margin
                       && my >= Top - margin && my <= Top + _h + margin;
            if (!_demo && inside != _expanded) SetExpanded(inside);

            Aim(_eyeL, mx, my);
            Aim(_eyeR, mx, my);
        }

        private void Aim(Grid eye, double mx, double my)
        {
            if (eye.ActualWidth <= 0) return;
            System.Windows.Point local;
            try { local = eye.TranslatePoint(new System.Windows.Point(eye.ActualWidth / 2, eye.ActualHeight / 2), this); }
            catch { return; }

            double ex = Left + local.X;
            double ey = Top + local.Y;
            double dx = mx - ex;
            double dy = my - ey;
            double len = Math.Sqrt(dx * dx + dy * dy);
            if (len < 1) return;

            double reach = 1.5;
            double ox = dx / len * reach;
            double oy = dy / len * reach;
            if (len < 40) { ox *= len / 40.0; oy *= len / 40.0; }

            if (eye.Children.Count < 2) return;
            var shift = ((FrameworkElement)eye.Children[1]).RenderTransform as TranslateTransform;
            if (shift == null) return;
            shift.X = ox;
            shift.Y = oy;
        }

        private void Blink()
        {
            if (!IsVisible) return;
            if (DateTime.UtcNow < _nextBlink) return;
            _nextBlink = DateTime.UtcNow.AddMilliseconds(4200 + Rnd.Next(3600));

            // Real eyelid blink: quick smooth close, tiny hold, slower open.
            // The old linear 70 ms flip read as a flicker; this reads as a blink.
            var easeIn = new SineEase();
            easeIn.EasingMode = EasingMode.EaseIn;
            var easeOut = new SineEase();
            easeOut.EasingMode = EasingMode.EaseOut;

            var blink = new DoubleAnimationUsingKeyFrames();
            blink.Duration = TimeSpan.FromMilliseconds(190);
            blink.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(0))));
            blink.KeyFrames.Add(new EasingDoubleKeyFrame(0.10, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(75)), easeIn));
            blink.KeyFrames.Add(new EasingDoubleKeyFrame(0.10, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(95))));
            blink.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(190)), easeOut));
            blink.Completed += delegate { _blink.ScaleY = 1; };
            _blink.BeginAnimation(ScaleTransform.ScaleYProperty, blink);
        }

        private void Place()
        {
            double scale = 1.0;
            PresentationSource src = PresentationSource.FromVisual(this);
            if (src != null && src.CompositionTarget != null)
                scale = src.CompositionTarget.TransformToDevice.M11;
            _scale = scale;

            System.Drawing.Rectangle wa;
            if (_hwnd != IntPtr.Zero && Native.IsWindow(_hwnd))
                wa = System.Windows.Forms.Screen.FromHandle(_hwnd).WorkingArea;
            else
                wa = System.Windows.Forms.Screen.PrimaryScreen.WorkingArea;

            double screenLeft = wa.Left / scale;
            double screenWidth = wa.Width / scale;
            double screenTop = wa.Top / scale;

            Left = screenLeft + (screenWidth - Width) / 2.0;
            Top = screenTop;
        }
    }

    internal static class Native
    {
        public const int SW_RESTORE = 9;
        public const int GWL_EXSTYLE = -20;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const uint GW_OWNER = 4;

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT lpPoint);
    }
}
