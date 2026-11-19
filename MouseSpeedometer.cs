// ============================================================
// 作成日：2026-11-20
// 目的　：マウスポインターの速度をリアルタイム表示するデスクトップガジェット（exe 版）
//         MouseSpeedometer.ps1 の C# 移植。設定ファイルは ps1 版と共通
//         （%APPDATA%\MouseSpeedometer\settings.json）
// ビルド：build.ps1 を実行（Windows 標準の csc.exe / C# 5 文法で記述）
// ============================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Mouse Speedometer")]
[assembly: AssemblyDescription("マウスポインターの速度をリアルタイム表示するガジェット")]
[assembly: AssemblyProduct("Mouse Speedometer")]
[assembly: AssemblyCopyright("Self-built")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace MouseSpeedometer
{
    // 設定値（ps1 版と同じキー）
    class Config
    {
        public string FontName = "Segoe UI";
        public int FontSize = 20;
        public double UpdateInterval = 0.5;   // 表示の更新間隔（秒）
        public bool Locked = false;
        public int X = 100;
        public int Y = 100;
    }

    // 設定ファイルの読み書き
    static class ConfigStore
    {
        public static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MouseSpeedometer");
        public static readonly string FilePath = Path.Combine(Dir, "settings.json");

        // 設定ファイルを読み込む（無い・壊れている場合は既定値）
        public static Config Load()
        {
            Config c = new Config();
            try
            {
                if (!File.Exists(FilePath)) return c;
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(FilePath));
                object v;
                CultureInfo inv = CultureInfo.InvariantCulture;
                if (d.TryGetValue("FontName", out v) && v != null) c.FontName = Convert.ToString(v, inv);
                if (d.TryGetValue("FontSize", out v) && v != null) c.FontSize = Convert.ToInt32(v, inv);
                if (d.TryGetValue("UpdateInterval", out v) && v != null) c.UpdateInterval = Convert.ToDouble(v, inv);
                if (d.TryGetValue("Locked", out v) && v != null) c.Locked = Convert.ToBoolean(v, inv);
                if (d.TryGetValue("X", out v) && v != null) c.X = Convert.ToInt32(v, inv);
                if (d.TryGetValue("Y", out v) && v != null) c.Y = Convert.ToInt32(v, inv);
            }
            catch { }
            c.FontSize = Math.Min(120, Math.Max(8, c.FontSize));
            c.UpdateInterval = Math.Min(2.0, Math.Max(0.1, c.UpdateInterval));
            return c;
        }

        // 設定ファイルへ保存する
        public static void Save(Config c)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var d = new Dictionary<string, object>();
                d["FontName"] = c.FontName;
                d["FontSize"] = c.FontSize;
                d["UpdateInterval"] = c.UpdateInterval;
                d["Locked"] = c.Locked;
                d["X"] = c.X;
                d["Y"] = c.Y;
                File.WriteAllText(FilePath, new JavaScriptSerializer().Serialize(d), new UTF8Encoding(true));
            }
            catch { }
        }
    }

    // 表示1行ぶん（見出し・数値・単位）
    class Row
    {
        public bool Big;
        public Label Cap, Num, Unit;
    }

    // ガジェット本体のウィンドウ
    class GadgetForm : Form
    {
        public const string Version = "1.1.0";
        static readonly Color BackCol = Color.FromArgb(30, 30, 30);
        static readonly Color ForeCol = Color.FromArgb(0, 255, 160);
        static readonly Color SubCol = Color.FromArgb(150, 210, 190);   // max. / avr. 行の色

        readonly Config cfg;
        readonly List<Row> rows = new List<Row>();
        readonly Row rowNow, rowMax, rowAvg;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Stopwatch watch = Stopwatch.StartNew();
        ContextMenuStrip menu;
        ToolStripMenuItem miLock;

        // 計測用
        Point lastPos;
        double lastMs;
        double accDist, accTime;              // 区間内の距離(px)・時間(秒)
        double maxSpeed, moveDist, moveTime;  // max. と avr. の集計

        // ドラッグ用
        bool dragging;
        Point dragStart, formStart;

        public GadgetForm()
        {
            cfg = ConfigStore.Load();
            if (!IsOnScreen(cfg.X, cfg.Y)) { cfg.X = 100; cfg.Y = 100; }

            Text = "Mouse Speed";
            FormBorderStyle = FormBorderStyle.None;
            TopMost = true;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = BackCol;
            Opacity = 0.85;
            DoubleBuffered = true;
            Location = new Point(cfg.X, cfg.Y);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            // 現在値（大）/ max.（小）/ avr.（小）の3行
            rowNow = NewRow(true, "", ForeCol);
            rowMax = NewRow(false, "max.", SubCol);
            rowAvg = NewRow(false, "avr.", SubCol);
            ApplyFont();

            BuildMenu();
            var targets = new List<Control> { this };
            foreach (Control c in Controls) targets.Add(c);
            foreach (Control c in targets)
            {
                c.MouseDown += OnDragDown;
                c.MouseMove += OnDragMove;
                c.MouseUp += OnDragUp;
                c.ContextMenuStrip = menu;
            }
            UpdateDragCursor();

            lastPos = Cursor.Position;
            timer.Interval = 50;
            timer.Tick += OnTick;
            timer.Start();
        }

        // 1行ぶんのラベルを作ってフォームに載せる
        Row NewRow(bool big, string caption, Color color)
        {
            Row r = new Row();
            r.Big = big;
            r.Cap = NewLabel(caption, ContentAlignment.MiddleLeft, color);
            r.Num = NewLabel("0", ContentAlignment.MiddleRight, color);
            r.Unit = NewLabel("px/s", ContentAlignment.MiddleLeft, color);
            rows.Add(r);
            return r;
        }

        // 表示用ラベルを1つ作る
        Label NewLabel(string text, ContentAlignment align, Color color)
        {
            Label l = new Label();
            l.AutoSize = false;
            l.Text = text;
            l.TextAlign = align;
            l.ForeColor = color;
            l.BackColor = BackCol;
            Controls.Add(l);
            return l;
        }

        // フォント名・サイズから Font を作る（使えないフォントなら既定フォント）
        public static Font MakeFont(string name, float size)
        {
            try
            {
                FontFamily ff = new FontFamily(name);
                if (ff.IsStyleAvailable(FontStyle.Regular)) return new Font(ff, size, FontStyle.Regular);
            }
            catch { }
            return new Font("Segoe UI", size);
        }

        // 設定のフォントを反映し、3行を「数字の右端」で揃えて配置する
        void ApplyFont()
        {
            Font big = MakeFont(cfg.FontName, cfg.FontSize);
            Font small = MakeFont(cfg.FontName, Math.Max(8, (int)Math.Round(cfg.FontSize * 0.5)));

            // 列幅：見出し列 + 数値列（5桁ぶん固定で桁数によるガタつき防止）
            int capW = TextRenderer.MeasureText("avr.", small).Width + 6;
            int numW = Math.Max(TextRenderer.MeasureText("88888", big).Width,
                                TextRenderer.MeasureText("88888", small).Width) + 4;
            int numRight = 10 + capW + numW;   // 全行共通の数字の右端

            int y = 4, right = 0;
            foreach (Row r in rows)
            {
                Font f = r.Big ? big : small;
                int h = TextRenderer.MeasureText("8", f).Height;
                int unitW = TextRenderer.MeasureText("px/s", f).Width + 2;
                r.Cap.Font = r.Num.Font = r.Unit.Font = f;
                r.Cap.SetBounds(10, y, capW, h);
                r.Num.SetBounds(numRight - numW, y, numW, h);
                r.Unit.SetBounds(numRight + 4, y, unitW, h);
                right = Math.Max(right, numRight + 4 + unitW);
                y += h;
            }
            ClientSize = new Size(right + 10, y + 4);
        }

        // 右クリックメニューを作る
        void BuildMenu()
        {
            menu = new ContextMenuStrip();

            miLock = new ToolStripMenuItem("この位置で固定");
            miLock.CheckOnClick = true;
            miLock.Checked = cfg.Locked;
            miLock.CheckedChanged += delegate
            {
                cfg.Locked = miLock.Checked;
                dragging = false;
                UpdateDragCursor();
                SaveConfig();
            };

            ToolStripMenuItem miReset = new ToolStripMenuItem("max. / avr. をリセット");
            miReset.Click += delegate { ResetStats(); };

            ToolStripMenuItem miSettings = new ToolStripMenuItem("設定...");
            miSettings.Click += delegate { ShowSettings(); };

            ToolStripMenuItem miAbout = new ToolStripMenuItem("About");
            miAbout.Click += delegate { ShowAbout(); };

            ToolStripMenuItem miExit = new ToolStripMenuItem("終了");
            miExit.Click += delegate { Close(); };

            menu.Items.AddRange(new ToolStripItem[] {
                miLock,
                new ToolStripSeparator(),
                miReset,
                new ToolStripSeparator(),
                miSettings,
                miAbout,
                new ToolStripSeparator(),
                miExit
            });
        }

        // 固定状態に応じてマウスカーソルの形を変える
        void UpdateDragCursor()
        {
            Cursor c = cfg.Locked ? Cursors.Default : Cursors.SizeAll;
            Cursor = c;
            foreach (Control ctl in Controls) ctl.Cursor = c;
        }

        // 座標がどれかの画面内にあるか判定する（モニター構成変更対策）
        static bool IsOnScreen(int x, int y)
        {
            foreach (Screen s in Screen.AllScreens)
                if (s.WorkingArea.Contains(x + 10, y + 10)) return true;
            return false;
        }

        // 現在の設定と位置を保存する
        void SaveConfig()
        {
            cfg.X = Left;
            cfg.Y = Top;
            ConfigStore.Save(cfg);
        }

        // max. / avr. の集計をリセットする
        void ResetStats()
        {
            maxSpeed = moveDist = moveTime = 0;
            rowMax.Num.Text = "0";
            rowAvg.Num.Text = "0";
        }

        // 10px/s 単位に丸める
        static double Round10(double v)
        {
            return Math.Round(v / 10) * 10;
        }

        // 50ms ごとの計測と、更新間隔ごとの表示更新
        void OnTick(object sender, EventArgs e)
        {
            double now = watch.Elapsed.TotalMilliseconds;
            double dt = (now - lastMs) / 1000.0;
            if (dt <= 0) return;

            Point p = Cursor.Position;
            double dx = p.X - lastPos.X, dy = p.Y - lastPos.Y;
            accDist += Math.Sqrt(dx * dx + dy * dy);
            accTime += dt;
            lastPos = p;
            lastMs = now;

            if (accTime < cfg.UpdateInterval) return;

            // 区間平均を表示
            double shown = Round10(accDist / accTime);
            rowNow.Num.Text = shown.ToString("0");

            // max.：区間平均の最大値 / avr.：止まっていた区間を除いた時間加重平均
            if (shown > maxSpeed) maxSpeed = shown;
            if (shown > 0) { moveDist += accDist; moveTime += accTime; }
            double mean = moveTime > 0 ? Round10(moveDist / moveTime) : 0;
            rowMax.Num.Text = maxSpeed.ToString("0");
            rowAvg.Num.Text = mean.ToString("0");

            accDist = accTime = 0;
        }

        // ドラッグ開始（固定していない時だけ）
        void OnDragDown(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && !cfg.Locked)
            {
                dragging = true;
                dragStart = Cursor.Position;
                formStart = Location;
            }
        }

        // ドラッグ中はウィンドウを追従させる
        void OnDragMove(object sender, MouseEventArgs e)
        {
            if (!dragging) return;
            Point p = Cursor.Position;
            Location = new Point(formStart.X + p.X - dragStart.X, formStart.Y + p.Y - dragStart.Y);
        }

        // ドラッグ終了で位置を保存
        void OnDragUp(object sender, MouseEventArgs e)
        {
            if (!dragging) return;
            dragging = false;
            SaveConfig();
        }

        // 設定ダイアログを表示する
        void ShowSettings()
        {
            using (SettingsDialog dlg = new SettingsDialog(cfg, BackCol, ForeCol))
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                cfg.FontName = dlg.FontNameValue;
                cfg.FontSize = dlg.FontSizeValue;
                cfg.UpdateInterval = dlg.IntervalValue;
                ApplyFont();
                SaveConfig();
            }
        }

        // About ダイアログを表示する
        void ShowAbout()
        {
            string msg = "Mouse Speedometer  v" + Version + "\r\n\r\n" +
                         "マウスポインターの移動速度（ピクセル/秒）をリアルタイム表示します。\r\n" +
                         "更新間隔ごとの平均値を 10px/s 単位で表示します。\r\n" +
                         "max.：最高速度 / avr.：動いていた時間の平均速度\r\n\r\n" +
                         "・左ドラッグ：移動（固定していない時）\r\n" +
                         "・右クリック：メニュー\r\n\r\n" +
                         "設定ファイル：\r\n" + ConfigStore.FilePath;
            MessageBox.Show(this, msg, "About", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            timer.Stop();
            SaveConfig();
            base.OnFormClosing(e);
        }
    }

    // 設定ダイアログ（フォント / サイズ / 更新間隔）
    class SettingsDialog : Form
    {
        readonly ComboBox cbFont = new ComboBox();
        readonly NumericUpDown numSize = new NumericUpDown();
        readonly NumericUpDown numInterval = new NumericUpDown();
        readonly Label preview = new Label();

        public string FontNameValue { get { return (string)cbFont.SelectedItem; } }
        public int FontSizeValue { get { return (int)numSize.Value; } }
        public double IntervalValue { get { return (double)numInterval.Value; } }

        public SettingsDialog(Config cfg, Color back, Color fore)
        {
            Text = "設定";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            ShowInTaskbar = false;
            ClientSize = new Size(S(360), S(306));

            // フォント種類
            AddLabel("フォント", 16, 20);
            cbFont.DropDownStyle = ComboBoxStyle.DropDownList;
            cbFont.SetBounds(S(90), S(16), S(250), 0);
            foreach (FontFamily ff in FontFamily.Families)
                if (ff.IsStyleAvailable(FontStyle.Regular)) cbFont.Items.Add(ff.Name);
            int idx = cbFont.Items.IndexOf(cfg.FontName);
            cbFont.SelectedIndex = idx >= 0 ? idx : 0;
            Controls.Add(cbFont);

            // フォントサイズ
            AddLabel("サイズ", 16, 56);
            numSize.Minimum = 8;
            numSize.Maximum = 120;
            numSize.Value = Math.Min(120, Math.Max(8, cfg.FontSize));
            numSize.SetBounds(S(90), S(52), S(80), 0);
            Controls.Add(numSize);

            // 表示の更新間隔（秒）
            AddLabel("更新間隔", 16, 92);
            numInterval.DecimalPlaces = 1;
            numInterval.Increment = 0.1m;
            numInterval.Minimum = 0.1m;
            numInterval.Maximum = 2.0m;
            numInterval.Value = (decimal)Math.Min(2.0, Math.Max(0.1, cfg.UpdateInterval));
            numInterval.SetBounds(S(90), S(88), S(80), 0);
            Controls.Add(numInterval);
            AddLabel("秒（大きいほど数字が落ち着く）", 176, 92);

            // プレビュー
            preview.Text = "1230 px/s";
            preview.TextAlign = ContentAlignment.MiddleCenter;
            preview.BorderStyle = BorderStyle.FixedSingle;
            preview.BackColor = back;
            preview.ForeColor = fore;
            preview.SetBounds(S(16), S(128), S(324), S(120));
            Controls.Add(preview);
            cbFont.SelectedIndexChanged += delegate { UpdatePreview(); };
            numSize.ValueChanged += delegate { UpdatePreview(); };
            UpdatePreview();

            // OK / キャンセル
            Button ok = new Button();
            ok.Text = "OK";
            ok.DialogResult = DialogResult.OK;
            ok.SetBounds(S(184), S(262), S(75), S(26));
            Button cancel = new Button();
            cancel.Text = "キャンセル";
            cancel.DialogResult = DialogResult.Cancel;
            cancel.SetBounds(S(266), S(262), S(75), S(26));
            Controls.Add(ok);
            Controls.Add(cancel);
            AcceptButton = ok;
            CancelButton = cancel;
        }

        // 高DPI 環境向けに座標をスケーリングする
        static int S(int v)
        {
            return (int)Math.Round(v * Program.DpiScale);
        }

        // 見出しラベルを置く
        void AddLabel(string text, int x, int y)
        {
            Label l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Location = new Point(S(x), S(y));
            Controls.Add(l);
        }

        // プレビューを現在の選択内容で更新する
        void UpdatePreview()
        {
            preview.Font = GadgetForm.MakeFont((string)cbFont.SelectedItem, (float)numSize.Value);
        }
    }

    static class Program
    {
        public static float DpiScale = 1f;

        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        // エントリーポイント（二重起動を防いでガジェットを開く）
        [STAThread]
        static void Main()
        {
            bool created;
            using (Mutex mutex = new Mutex(true, "MouseSpeedometer_SingleInstance", out created))
            {
                if (!created)
                {
                    MessageBox.Show("Mouse Speedometer はすでに起動しています。", "Mouse Speedometer");
                    return;
                }
                try { SetProcessDPIAware(); } catch { }
                using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) DpiScale = g.DpiX / 96f;

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new GadgetForm());
            }
        }
    }
}
