// Tech Kit custom PowerShell host.
// Captures everything a script writes (output, Write-Host colors, warnings, What-If
// messages, progress) into a thread-safe queue that the GUI drains on a timer.
// Prompts (Read-Host, Get-Credential, confirmation choices) are handed to the GUI
// thread through PendingPrompt and the worker thread waits for the answer.
//
// Written in C# 5 syntax on purpose: Windows PowerShell 5.1 compiles Add-Type code
// with the .NET Framework compiler, which does not understand newer C# features.

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace TechKit
{
    public class OutputItem
    {
        public string Kind;        // Output, Host, Error, Warning, Verbose, Debug, Info, Success, System, Command, Progress, Clear, End
        public string Text;
        public int Color = -1;     // ConsoleColor value, -1 means "default for this kind"
        public bool NewLine = true;
        public string Channel;     // "output" or "terminal"
        public int Percent = -1;
        public string Activity;
        public bool Completed;
    }

    public class PromptRequest
    {
        public string Type;            // ReadLine, Secure, Credential, Choice
        public string Caption;
        public string Message;
        public string UserName;
        public string[] Choices;
        public string[] ChoiceHelp;
        public int DefaultChoice;
        public object Response;
        public bool Cancelled;
        public bool Taken;             // set by the GUI when it starts showing the dialog
        public ManualResetEvent Done = new ManualResetEvent(false);
    }

    public class OutputSink
    {
        private ConcurrentQueue<OutputItem> queue = new ConcurrentQueue<OutputItem>();
        private object fileLock = new object();
        private static Regex ansi = new Regex("\u001b\\[[0-9;?]*[ -/]*[@-~]", RegexOptions.Compiled);

        public string FilePath;            // when set, items are appended to this file as JSON lines (elevated runs)
        public string Channel = "output";
        public bool Interactive = true;    // false: prompts are cancelled automatically
        public string Location = "";
        public volatile PromptRequest PendingPrompt;

        public void Add(string kind, string text)
        {
            Add(kind, text, -1, true);
        }

        public void Add(string kind, string text, int color, bool newLine)
        {
            OutputItem item = new OutputItem();
            item.Kind = kind;
            item.Text = text == null ? "" : ansi.Replace(text, "");
            item.Color = color;
            item.NewLine = newLine;
            item.Channel = Channel;
            Push(item);
        }

        public void Progress(string activity, string status, int percent, bool completed)
        {
            OutputItem item = new OutputItem();
            item.Kind = "Progress";
            item.Activity = activity;
            item.Text = status;
            item.Percent = percent;
            item.Completed = completed;
            item.Channel = Channel;
            Push(item);
        }

        private void Push(OutputItem item)
        {
            if (!String.IsNullOrEmpty(FilePath))
            {
                lock (fileLock)
                {
                    File.AppendAllText(FilePath, ToJson(item) + "\n", new UTF8Encoding(false));
                }
                return;
            }
            queue.Enqueue(item);
        }

        public OutputItem[] Drain(int max)
        {
            List<OutputItem> list = new List<OutputItem>();
            OutputItem item;
            while (list.Count < max && queue.TryDequeue(out item))
            {
                list.Add(item);
            }
            return list.ToArray();
        }

        public bool HasItems
        {
            get { return !queue.IsEmpty; }
        }

        public PromptRequest Ask(PromptRequest request)
        {
            if (!Interactive)
            {
                request.Cancelled = true;
                return request;
            }
            PendingPrompt = request;
            request.Done.WaitOne();
            PendingPrompt = null;
            return request;
        }

        public static string ToJson(OutputItem item)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"Kind\":").Append(Quote(item.Kind));
            sb.Append(",\"Text\":").Append(Quote(item.Text));
            sb.Append(",\"Color\":").Append(item.Color.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"NewLine\":").Append(item.NewLine ? "true" : "false");
            sb.Append(",\"Percent\":").Append(item.Percent.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"Activity\":").Append(Quote(item.Activity));
            sb.Append(",\"Completed\":").Append(item.Completed ? "true" : "false");
            sb.Append("}");
            return sb.ToString();
        }

        private static string Quote(string s)
        {
            if (s == null) return "null";
            StringBuilder sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) { sb.Append("\\u").Append(((int)c).ToString("x4")); }
                        else { sb.Append(c); }
                        break;
                }
            }
            sb.Append("\"");
            return sb.ToString();
        }
    }

    public class Host : PSHost
    {
        private Guid id = Guid.NewGuid();
        private HostUI ui;
        private string name;
        private CultureInfo culture;
        private CultureInfo uiCulture;
        public OutputSink Sink;

        public Host(OutputSink sink, string hostName)
        {
            Sink = sink;
            name = hostName;
            ui = new HostUI(sink);
            culture = Thread.CurrentThread.CurrentCulture;
            uiCulture = Thread.CurrentThread.CurrentUICulture;
        }

        public override string Name { get { return name; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override Guid InstanceId { get { return id; } }
        public override PSHostUserInterface UI { get { return ui; } }
        public override CultureInfo CurrentCulture { get { return culture; } }
        public override CultureInfo CurrentUICulture { get { return uiCulture; } }

        public override void EnterNestedPrompt()
        {
            throw new NotSupportedException("Nested prompts are not supported in Tech Kit.");
        }

        public override void ExitNestedPrompt() { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }

        public override void SetShouldExit(int exitCode)
        {
            Sink.Add("System", "(exit " + exitCode.ToString(CultureInfo.InvariantCulture) + " ignored: close the Tech Kit window to quit)");
        }
    }

    public class HostUI : PSHostUserInterface
    {
        private OutputSink sink;
        private RawUI raw = new RawUI();
        private string lastWrite = "";

        // Values set from PowerShell can arrive wrapped in a PSObject.
        private static object Unwrap(object value)
        {
            PSObject pso = value as PSObject;
            if (pso != null) return pso.BaseObject;
            return value;
        }

        public HostUI(OutputSink s)
        {
            sink = s;
            raw.Clear = delegate { sink.Add("Clear", ""); };
        }

        public override PSHostRawUserInterface RawUI { get { return raw; } }

        public override void Write(string value)
        {
            lastWrite = value;
            sink.Add("Host", value, -1, false);
        }

        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value)
        {
            lastWrite = value;
            sink.Add("Host", value, (int)foregroundColor, false);
        }

        public override void WriteLine(string value)
        {
            sink.Add("Host", value, -1, true);
        }

        public override void WriteLine()
        {
            sink.Add("Host", "", -1, true);
        }

        public override void WriteLine(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value)
        {
            sink.Add("Host", value, (int)foregroundColor, true);
        }

        public override void WriteErrorLine(string value)
        {
            sink.Add("Error", value);
        }

        public override void WriteWarningLine(string message)
        {
            sink.Add("Warning", "WARNING: " + message);
        }

        public override void WriteVerboseLine(string message)
        {
            sink.Add("Verbose", "VERBOSE: " + message);
        }

        public override void WriteDebugLine(string message)
        {
            sink.Add("Debug", "DEBUG: " + message);
        }

        public override void WriteProgress(long sourceId, ProgressRecord record)
        {
            if (record == null) return;
            bool done = record.RecordType == ProgressRecordType.Completed;
            string status = record.StatusDescription;
            if (!String.IsNullOrEmpty(record.CurrentOperation)) status = status + " - " + record.CurrentOperation;
            sink.Progress(record.Activity, status, record.PercentComplete, done);
        }

        public override string ReadLine()
        {
            PromptRequest r = new PromptRequest();
            r.Type = "ReadLine";
            r.Caption = "Input needed";
            r.Message = lastWrite;
            sink.Ask(r);
            if (r.Cancelled) throw new PromptingException("Input was cancelled.");
            object raw = Unwrap(r.Response);
            string answer = raw == null ? "" : raw.ToString();
            sink.Add("Host", answer == null ? "" : answer, -1, true);
            return answer == null ? "" : answer;
        }

        public override SecureString ReadLineAsSecureString()
        {
            PromptRequest r = new PromptRequest();
            r.Type = "Secure";
            r.Caption = "Secure input needed";
            r.Message = lastWrite;
            sink.Ask(r);
            if (r.Cancelled) throw new PromptingException("Input was cancelled.");
            sink.Add("Host", "********", -1, true);
            SecureString ss = Unwrap(r.Response) as SecureString;
            return ss == null ? new SecureString() : ss;
        }

        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
        {
            Dictionary<string, PSObject> result = new Dictionary<string, PSObject>();
            foreach (FieldDescription fd in descriptions)
            {
                string typeName = fd.ParameterTypeFullName == null ? "" : fd.ParameterTypeFullName;
                string label = String.IsNullOrEmpty(fd.Label) ? fd.Name : fd.Label;
                label = label.Replace("&", "");
                PromptRequest r = new PromptRequest();
                r.Caption = String.IsNullOrEmpty(caption) ? "Input needed" : caption;
                r.Message = (String.IsNullOrEmpty(message) ? "" : message + "\n") + label + (String.IsNullOrEmpty(fd.HelpMessage) ? "" : "\n" + fd.HelpMessage);
                if (typeName.EndsWith("PSCredential", StringComparison.OrdinalIgnoreCase))
                {
                    r.Type = "Credential";
                }
                else if (typeName.EndsWith("SecureString", StringComparison.OrdinalIgnoreCase))
                {
                    r.Type = "Secure";
                }
                else
                {
                    r.Type = "ReadLine";
                }
                sink.Ask(r);
                if (r.Cancelled) throw new PromptingException("Input was cancelled.");
                object value = Unwrap(r.Response);
                if (value == null) value = "";
                result[fd.Name] = new PSObject(value);
            }
            return result;
        }

        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            PromptRequest r = new PromptRequest();
            r.Type = "Choice";
            r.Caption = String.IsNullOrEmpty(caption) ? "Choose an option" : caption;
            r.Message = message;
            r.DefaultChoice = defaultChoice;
            r.Choices = new string[choices.Count];
            r.ChoiceHelp = new string[choices.Count];
            for (int i = 0; i < choices.Count; i++)
            {
                r.Choices[i] = choices[i].Label;
                r.ChoiceHelp[i] = choices[i].HelpMessage;
            }
            sink.Ask(r);
            if (r.Cancelled)
            {
                if (defaultChoice >= 0) return defaultChoice;
                throw new PromptingException("Choice was cancelled.");
            }
            return Convert.ToInt32(Unwrap(r.Response), CultureInfo.InvariantCulture);
        }

        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
        {
            PromptRequest r = new PromptRequest();
            r.Type = "Credential";
            r.Caption = String.IsNullOrEmpty(caption) ? "Credentials needed" : caption;
            r.Message = message;
            r.UserName = userName;
            sink.Ask(r);
            if (r.Cancelled) return null;
            return Unwrap(r.Response) as PSCredential;
        }

        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options)
        {
            return PromptForCredential(caption, message, userName, targetName);
        }
    }

    public class RawUI : PSHostRawUserInterface
    {
        private ConsoleColor fg = ConsoleColor.Gray;
        private ConsoleColor bg = ConsoleColor.Black;
        private Size buffer = new Size(220, 9999);
        private Coordinates cursor = new Coordinates(0, 0);
        private string title = "Tech Kit";

        public override ConsoleColor ForegroundColor { get { return fg; } set { fg = value; } }
        public override ConsoleColor BackgroundColor { get { return bg; } set { bg = value; } }
        public override Size BufferSize { get { return buffer; } set { buffer = value; } }
        public override Coordinates CursorPosition { get { return cursor; } set { cursor = value; } }
        public override int CursorSize { get { return 25; } set { } }
        public override bool KeyAvailable { get { return false; } }
        public override Size MaxPhysicalWindowSize { get { return new Size(buffer.Width, 120); } }
        public override Size MaxWindowSize { get { return new Size(buffer.Width, 120); } }
        public override Coordinates WindowPosition { get { return new Coordinates(0, 0); } set { } }
        public override Size WindowSize { get { return new Size(buffer.Width, 60); } set { } }
        public override string WindowTitle { get { return title; } set { title = value; } }

        public override void FlushInputBuffer() { }

        public override BufferCell[,] GetBufferContents(Rectangle rectangle)
        {
            throw new NotSupportedException("Reading the screen buffer is not supported in Tech Kit.");
        }

        public override KeyInfo ReadKey(ReadKeyOptions options)
        {
            throw new NotSupportedException("ReadKey / 'press any key' is not supported in Tech Kit. Use script parameters instead.");
        }

        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { }
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { }

        public override void SetBufferContents(Rectangle rectangle, BufferCell fill)
        {
            // Clear-Host passes a rectangle of -1s. Tell the GUI to clear the pane.
            if (rectangle.Left == -1 && rectangle.Right == -1 && Clear != null)
            {
                Clear();
            }
        }

        public Action Clear;
    }
}
