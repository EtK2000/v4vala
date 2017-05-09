/*********************************
 *            v4vala             *
 *                               *
 *    The free vala IDE built    *
 *     by EtK2000 using vala     *
 *                               *
 * Copyright © 2016-2017 EtK2000 *
 *********************************/

using Gdk;
using Gtk;
using GLib.Environment;
using GLib.FileUtils;

public class ValaIDE : Gtk.Window {
	private static const double VERSION = 0.01;
	private static SourceLanguageManager slm = new SourceLanguageManager();
	
	private class Dictionary {
		private Array<string> keys = new Array<string>();
		private Array<string> values = new Array<string>();
		
		private int index_of(string key) {
			for (unowned int i = 0; i < keys.length; i++) {
				if (keys.index(i) == key)
					return i;
			}
			return -1;
		}
		
		public string get(string key) {
			return get_or_default(key, "");
		}
		
		public unowned string get_or_default(string key, string def) {
			int i = index_of(key);
			if (i != -1)
				return values.index(i);
			return def;
		}
		
		public string put(string key, string val) {
			int i = index_of(key);
			if (i == -1) {// doesn't exist, so add it!
				keys.append_val(key);
				values.append_val(val);
				return "";
			}// it exists, so overwrite its data
			string res = values.index(i);
			values.remove_index(i);
			values.insert_val(i, val);
			return res;
		}
	}
	
	public class SearchDialog : Dialog {
		private Entry search_entry;
		private CheckButton match_case;
		private CheckButton find_backwards;
		private Widget find_button;
		
		public signal void find_next(string text, bool case_sensitivity);
		public signal void find_previous(string text, bool case_sensitivity);
		
		public SearchDialog(Gtk.Window parent) {
			this.parent = parent;
			this.title = "Find";
			this.border_width = 5;
			set_default_size(350, 100);
			create_widgets();
			connect_signals();
		}
		
		private void create_widgets () {
			// Create and setup widgets
			search_entry = new Entry();
			var search_label = new Label.with_mnemonic("_Search for:");
			search_label.mnemonic_widget = search_entry;
			match_case = new CheckButton.with_mnemonic("_Match case");
			find_backwards = new CheckButton.with_mnemonic("Find _backwards");
			
			// Layout widgets
			var hbox = new Box(Orientation.HORIZONTAL, 20);
			hbox.pack_start(search_label, false, true, 0);
			hbox.pack_start(search_entry, true, true, 0);
			var content = get_content_area() as Box;
			content.pack_start(hbox, false, true, 0);
			content.pack_start(match_case, false, true, 0);
			content.pack_start(find_backwards, false, true, 0);
			content.spacing = 10;
			
			// Add buttons to button area at the bottom
			add_button(Stock.HELP, ResponseType.HELP);
			add_button(Stock.CLOSE, ResponseType.CLOSE);
			find_button = add_button (Stock.FIND, ResponseType.APPLY);
			find_button.sensitive = false;
			
			show_all();
		}
		
		private void connect_signals() {
			search_entry.changed.connect(() => find_button.sensitive = (search_entry.text != ""));
			response.connect(on_response);
		}

		private void on_response(Dialog source, int response_id) {
			switch (response_id) {
				case ResponseType.HELP:
					// show_help ();
					break;
				case ResponseType.APPLY:
					on_find_clicked();
					break;
				case ResponseType.CLOSE:
					destroy();
					break;
			}
		}
		
		private void on_find_clicked() {
			string text = search_entry.text;
			bool cs = match_case.active;
			if (find_backwards.active)
				find_previous(text, cs);
			else
				find_next(text, cs);
		}
	}
	
	private class SourceLabel : HBox {
		private static int x = 1;
		private string? f;
		private Label l;
		
		public SourceLabel(string? file = null) {
			f = file;
			l = new Label("");
			
			if (f == null)
				l.set_text("new " + (x++).to_string());
			else
				set_label();
			
			// setup the x button
			EventBox b = new EventBox();
			Image image = new Image.from_pixbuf(b.render_icon(Stock.CLOSE, IconSize.BUTTON, null).scale_simple(8, 8, InterpType.BILINEAR));
			b.add(image);
			
			// remove the tab if x is clicked, TODO: warn the user if any changes were made
			b.button_press_event.connect((e) => {
				Notebook p = (Notebook) get_parent();
				for (int i = 0 ; i < p.get_n_pages(); i++) {
					if (p.get_tab_label(p.get_nth_page(i)) == this) {
						p.remove_page(i);
						p.show_tabs = p.get_n_pages() > 1;
						break;
					}
				}
				return true;
			});
			
			pack_start(l, true, true, 0);
			pack_start(b, false, false, 1);
			show_all();
		}
		
		// sets the label text to file data, note: f != null
		private void set_label() {
			l.set_text(File.new_for_path(f).get_basename());
			l.set_tooltip_text(f);
		}
		
		public unowned string? file() {
			return f;
		}
		
		public void set_file(string file) {
			f = file;
			set_label();
		}
	}
	
	public static int main(string[] args) {
		Gtk.init(ref args);
		
		ValaIDE ide = new ValaIDE();
		ide.destroy.connect(main_quit);
		ide.update_check.begin();
		Gtk.main();
		
		return 0;
	}
	
	private string locale;
	private string valaDir;
	private string vapiDir;
	private Dictionary lang;
	private Notebook sources;
	private Statusbar status;
	private ToolButton compile_button;
	private ToolButton run_button;
	private ToolButton stop_button;
	private Gee.HashMap<Widget, string> localize = new Gee.HashMap<Widget, string>();
	private bool running = false;// is a sub-process running
	
	public ValaIDE() {
		try {
			Dictionary props = read_properties(File.new_for_uri(get_current_dir() + "/v4vala.cfg"), false);
			locale = props.get_or_default("lang", "en_US");
			valaDir = props.get("dir_vala");
			vapiDir = props.get("dir_vapi");
		}
		catch (Error e) {}// it will NEVER get here
		
		try {
			// Either directly from a file ...
			icon = new Pixbuf.from_file("my-app.png");
			// ... or from the theme
			icon = IconTheme.get_default().load_icon("my-app", 48, 0);
		}
		catch (Error e) {
			stderr.printf("Could not load application icon: %s\n", e.message);
		}
		
		// setup the window
		set_default_direction(TextDirection.LTR);
		title = "v4vala, Vala IDE by EtK2000";
		border_width = 10;
		window_position = WindowPosition.CENTER;
		set_default_size(800, 600);
		addDnD(this);
		
		var toolbar = new Toolbar();
		toolbar.get_style_context().add_class(STYLE_CLASS_PRIMARY_TOOLBAR);
		
		// create the toolbar
		var open_button = new ToolButton(new Image.from_icon_name("document-open", IconSize.SMALL_TOOLBAR), "");
		open_button.is_important = true;
		toolbar.add(open_button);
		open_button.clicked.connect(on_open_clicked);
		localize[open_button] = "open";
		
		var save_button = new ToolButton(new Image.from_icon_name("document-save", IconSize.SMALL_TOOLBAR), "");
		save_button.is_important = true;
		toolbar.add(save_button);
		save_button.clicked.connect((_) => do_save());
		localize[save_button] = "save";
		
		compile_button = new ToolButton(new Image.from_icon_name("system-run", IconSize.SMALL_TOOLBAR), "");
		compile_button.is_important = true;
		toolbar.add(compile_button);
		compile_button.clicked.connect(compile);
		localize[compile_button] = "compile";
		
		run_button = new ToolButton(new Image.from_icon_name("system-run", IconSize.SMALL_TOOLBAR), "");
		run_button.is_important = true;
		toolbar.add(run_button);
		run_button.clicked.connect(run);
		localize[run_button] = "run";
		
		stop_button = new ToolButton(new Image.from_icon_name("process-stop", IconSize.SMALL_TOOLBAR), "");
		stop_button.is_important = true;
		toolbar.add(stop_button);
		stop_button.clicked.connect(stop);
		localize[stop_button] = "stop";
		
		var style_button = new ToolButton(new Image.from_icon_name("gtk-convert", IconSize.SMALL_TOOLBAR), "");
		style_button.is_important = true;
		toolbar.add(style_button);
		style_button.clicked.connect(() => {
			//SourceStyleSchemeChooserButton
		});
		localize[style_button] = "style";
		
		/*********************/
		/* setup the menubar */
		/*********************/
		
		MenuBar menu = new MenuBar();
		
		Gtk.MenuItem file = new Gtk.MenuItem();
		localize[file] = "menu_file";
		{
			Gtk.Menu submenu = new Gtk.Menu();
			file.set_submenu(submenu);
			
			Gtk.MenuItem _new = new Gtk.MenuItem();
			Gtk.MenuItem open = new Gtk.MenuItem();
			Gtk.MenuItem save = new Gtk.MenuItem();
			Gtk.MenuItem saveAs = new Gtk.MenuItem();
			
			localize[_new] = "menu_file_new";
			localize[open] = "menu_file_open";
			localize[save] = "menu_file_save";
			localize[saveAs] = "menu_file_saveas";
			
			_new.activate.connect(() => build_source_area());
			open.activate.connect(on_open_clicked);
			save.activate.connect(() => do_save());
			saveAs.activate.connect(() => do_save(true));
			
			submenu.add(_new);
			submenu.add(open);
			submenu.add(save);
			submenu.add(saveAs);
		}
		menu.add(file);
		
		Gtk.MenuItem window = new Gtk.MenuItem();
		localize[window] = "menu_window";
		{
			Gtk.Menu submenu = new Gtk.Menu();
			window.set_submenu(submenu);
			
			Gtk.MenuItem _lang = new Gtk.MenuItem();
			localize[_lang] = "menu_window_lang";
			
			
			Gtk.Menu lsubmenu = new Gtk.Menu();
			_lang.set_submenu(lsubmenu);
			
			// add all languages to the language menu
			{// TODO: show languages for all files in the lang folder
				Gtk.MenuItem l;
				
				string langs[2] = {"English", "עברית"};
				foreach (string _l in langs) {
					l = new Gtk.MenuItem.with_label(_l);
			
					l.activate.connect(() => {
						locale = _l;
						load_locale();
						save_config();
					});
					lsubmenu.add(l);
				}
			}
			
			submenu.add(_lang);
		}
		menu.add(window);
		
		Gtk.MenuItem help = new Gtk.MenuItem();
		localize[help] = "menu_help";
		{
			Gtk.Menu submenu = new Gtk.Menu();
			help.set_submenu(submenu);
			
			Gtk.MenuItem about = new Gtk.MenuItem();
			Gtk.MenuItem update = new Gtk.MenuItem();
			
			localize[about] = "menu_help_about";
			localize[update] = "menu_help_update";
			
			/****************/
			/* About Dialog */
			/****************/
			AboutDialog dialog = new AboutDialog();
			dialog.set_destroy_with_parent(true);
			dialog.set_transient_for(this);
			dialog.set_modal(true);
			
			dialog.artists = null;
			dialog.authors = {"EtK2000"};
			dialog.documenters = null;
			dialog.translator_credits = "EtK2000";
			
			dialog.program_name = "v4vala";
			dialog.comments = null;
			dialog.copyright = "Copyright © 2016-2017 EtK2000";
			dialog.version = "%.2f".printf(VERSION);
			
			string text;
			get_contents("license.txt", out text);
			dialog.license = text;
			dialog.wrap_license = true;
			
			dialog.website = "https://etk2000.com";
			dialog.website_label = "EtK2000.com";
			
			dialog.response.connect((response_id) => {
				if (response_id == Gtk.ResponseType.CANCEL || response_id == Gtk.ResponseType.DELETE_EVENT) {
					dialog.hide_on_delete ();
				}
			});
			
			about.activate.connect(() => dialog.present());
			update.activate.connect(() => update_check.begin());
			
			submenu.add(about);
			submenu.add(update);
		}
		menu.add(help);
		
		// create the default area
		sources = new Notebook();
		build_source_area();
		
		var vbox = new Box(Orientation.VERTICAL, 0);
		
		vbox.pack_start(menu, false, false, 0);
		vbox.pack_start(toolbar, false, false, 0);
		vbox.pack_start(sources, true, true, 0);
		
		// the status bar xD
		status = new Statusbar();
		vbox.pack_start(status, false, false, 0);
		
		add(vbox);
		
		load_locale();
		show_all();
		stop_button.set_visible(false);
	}
	
	private void load_locale() {
		try {
			lang = read_properties(File.new_for_uri(get_current_dir() + "/lang/" + locale + ".lang"), false);
			foreach (var e in localize.entries) {
				if (e.key is Gtk.MenuItem)
					((Gtk.MenuItem) e.key).set_label(lang.get(e.value));
				else if (e.key is Label)
					((Label) e.key).set_text(lang.get(e.value));
				else if (e.key is ToolButton)
					((ToolButton) e.key).set_label(lang.get(e.value));
				// TODO: add all types
				e.key.set_tooltip_text(lang.get(e.value + "_tooltip"));
			}
		}
		catch (Error e) {}// it shouldn't get here
	}
	
	private void addDnD(Widget w) {
		w.drag_data_received.connect(on_drag_data_received);
		TargetEntry te = {"text/uri-list", 0, 80};
		drag_dest_set(w, DestDefaults.MOTION | DestDefaults.HIGHLIGHT | DestDefaults.DROP, {te}, DragAction.COPY);
	}
	
	private void save_config() {
		try {
			set_contents(get_current_dir() + "/v4vala.cfg",
				"dir_vala=" +	valaDir +
				"\ndir_vapi=" +	vapiDir +
				"\nlang=" + locale + 
				"\n"
			);
		}
		catch(FileError e) {
			errorMsg("Failed to save config:\n" + e.message);
		}
	}
	
	private void build_source_area(string? file = null) {
		var syntaxView = syntax_view();
		sources.append_page(syntaxView, new SourceLabel(file));
		sources.show_all();
		sources.set_tab_reorderable(syntaxView, true);// allow reordering this
		sources.show_tabs = sources.get_n_pages() > 1;
	}
	
	private ScrolledWindow syntax_view() {
		SourceView tv = new SourceView();
		tv.set_show_line_numbers(true);
		tv.set_auto_indent(true);
		((SourceBuffer) tv.buffer).set_language(slm.get_language("vala"));
		
		// for some reason the monospace doesn't work...
		
		/* TODO: why doesn't this work?
		SourceCompletionWords keyword_provider = new SourceCompletionWords("keywords", null);
		keyword_provider.register(tv.buffer);
		tv.get_completion().add_provider(keyword_provider);*/
		
		// make it scrollable, TODO: is this required anymore?
		ScrolledWindow scroll = new ScrolledWindow(null, null);
		scroll.set_policy(PolicyType.AUTOMATIC, PolicyType.AUTOMATIC);
		scroll.add(tv);
		
		addDnD(tv);
		tv.key_press_event.connect(key_press_callback);
		
		return scroll;
	}
	
	bool key_press_callback(EventKey event) {
		if ((event.state & ModifierType.CONTROL_MASK) == 0)
			return false;
		
		if (event.keyval == 102) {// CTRL+F
			var find = new SearchDialog(this);
			find.modal = true;
			find.set_position(WindowPosition.CENTER_ON_PARENT);
			find.show();
		}
		else
			return false;
		return true;
	}
	
	private TextView get_source() {
		return get_source_n(sources.get_current_page());
	}
	
	private TextView get_source_n(int n) {
		return (TextView)(((Container) sources.get_nth_page(n)).get_children().nth_data(0));
	}
	
	private void valac(bool run) {
		if (!(File.new_for_path(valaDir + "/valac").query_exists() || File.new_for_path(valaDir + "/valac.exe").query_exists())) {
			// no vala was found, ask the user to find it
			var file_chooser = new FileChooserDialog("Select Vala Directory", this, FileChooserAction.SELECT_FOLDER, "_Cancel", ResponseType.CANCEL, "_Open", ResponseType.ACCEPT);
			if (file_chooser.run() == ResponseType.ACCEPT) {
				if (File.new_for_path(file_chooser.get_filename() + "/valac").query_exists() || File.new_for_path(file_chooser.get_filename() + "/valac.exe").query_exists()) {
					valaDir = file_chooser.get_filename();// vala was found!
					save_config();
				}
				else {
					MessageDialog msg = new MessageDialog(this, DialogFlags.MODAL, MessageType.WARNING, ButtonsType.OK, "No valac found!\nPlease select a directory that contains vala.");
					msg.response.connect((response_id) => {
						msg.destroy();
						valac(run);
					});
					msg.show();
					file_chooser.destroy();
					return;
				}
			}
			file_chooser.destroy();
		}
		try {
			string tmp = get_tmp_dir().replace("\\", "/") + "/tmp.vala";
			set_contents(tmp, get_source().buffer.text);
			
			int exitCode;
			string std_out, std_err;
			Process.spawn_command_line_sync("\"" + valaDir + "/valac\"" +// specify the valac path
				(vapiDir != "" ? " --vapidir \"" + vapiDir + "\"": "") +// specify the vapi path if needed
				" --pkg gtk+-3.0 " +// TODO: specify packages user selected
				(run ? "" : "-c ") + tmp, out std_out, out std_err, out exitCode);// specify the tmp file to compile
			
			if (std_err.index_of("not found in specified Vala API directories") != -1) {
				// we need to point to the vapi folder
				
				var file_chooser = new FileChooserDialog("Select Vapi Directory", this, FileChooserAction.SELECT_FOLDER, "_Cancel", ResponseType.CANCEL, "_Open", ResponseType.ACCEPT);
				if (file_chooser.run() == ResponseType.ACCEPT) {
					if (File.new_for_path(file_chooser.get_filename() + "/gtk+-3.0.vapi").query_exists()) {
						vapiDir = file_chooser.get_filename();// vapis seem found!
						save_config();
					}
					else {
						MessageDialog msg = new MessageDialog(this, DialogFlags.MODAL, MessageType.WARNING, ButtonsType.OK, "No vapis found!\nPlease select a directory that contains your vapi files.");
						msg.response.connect((response_id) => {
							msg.destroy();
							valac(run);
						});
						msg.show();
						file_chooser.destroy();
						return;
					}
				}
				file_chooser.destroy();
				
			}
			else if (std_err != "")
				stdout.printf("valac stderr: %s\n", std_err);
			
			status.push(status.get_context_id("valac"), std_out != "" ? std_out : "Compilation succeeded");
			
			// delete the object if it compiled or rename it if we built
			if (run) {
				File out = File.new_for_path(get_current_dir() + "/tmp.exe");// TODO: find a cross-platform way to do this
				string exe = ((SourceLabel) sources.get_tab_label(sources.get_nth_page(sources.get_current_page()))).file() + ".exe";
				if (out.query_exists())
					out.move(File.new_for_path(exe), FileCopyFlags.OVERWRITE, null, null);
				// run the file
				stdout.printf("running %s...\n--------------------\n\n", exe);
				
				//Subprocess s = Subprocess.newv({exe}, GLib.SubprocessFlags.INHERIT_FDS);
				
				//s.wait();
				
				compile_button.set_visible(false);
				run_button.set_visible(false);
				stop_button.set_visible(true);
				
				// this is a temporary way of sending input to the running process
				string text = "";
				try {
					get_contents("stdin.txt", out text);
				} catch (Error e) {
					errorMsg(e.message);
				}
				
				Pid child_pid;
				int std_in;
				running = Process.spawn_async_with_pipes(".", {exe}, null, SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out child_pid, out std_in, null, null);  
				FileStream instream = FileStream.fdopen(std_in, "w");
				instream.write(text.data);
				// TODO: get instream data from user
				
				ChildWatch.add(child_pid, (pid, status) => {
					running = false;
					Process.close_pid(pid);
					stdout.printf("\n--------------------\ndone, exit code: %i\n", status);
					
					stop_button.set_visible(false);
					compile_button.set_visible(true);
					run_button.set_visible(true);
				});
				
				// TODO: lock UI thread (or at least parts of it) until the process exits
			}
			else {
				File out = File.new_for_path(get_current_dir() + "/tmp.vala.o");
				if (out.query_exists())
					out.delete();
			}
		}
		catch (Error e) {
			stderr.printf("%s\n", e.message);
		}
	}
	
	private void compile() {
		valac(false);
	}
	
	private void run() {
		valac(true);
	}
	
	private void stop() {
		if (running) {
		}
	}
	
	// TODO: find a better way to fix the multiple drag issue, it works fine on the IDE, just not on the SourceArea
	int id = 0;
	private void on_drag_data_received(DragContext context, int x, int y, SelectionData selection_data, uint info, uint time) {
		try {
			if (++id % 2 == 0 || id == 1) {
				// add the new file to the notebook
				open(Filename.from_uri(selection_data.get_uris()[0]));
				// add the new file to the recent files list
				RecentManager.get_default().add_item(selection_data.get_uris()[0]);
			}
		}
		catch (ConvertError e){}// it should never be thrown...
	}
	
	private void open(string filename) {
		// remove the "new" if it's empty
		if (((SourceLabel) sources.get_tab_label(sources.get_nth_page(0))).file() == null && get_source_n(0).buffer.get_char_count() == 0)
			sources.remove_page(0);
	
		build_source_area(filename);
		sources.set_current_page(sources.get_n_pages() - 1);
		
		// attempt to load the text into the new source element
		try {
			string text;
			SourceBuffer buffer = (SourceBuffer) get_source().buffer;
			get_contents(filename, out text);
			buffer.begin_not_undoable_action();
			buffer.text = text;
			buffer.end_not_undoable_action();
		} catch (Error e) {
			errorMsg(e.message);
		}
	}
	
	private void on_open_clicked() {
		var file_chooser = new FileChooserDialog(lang.get("dialog_open"), this, FileChooserAction.OPEN, "_Cancel", ResponseType.CANCEL, "_Open", ResponseType.ACCEPT);
		if (file_chooser.run() == ResponseType.ACCEPT) {
			// add the new file to the notebook
			open(file_chooser.get_filename());
		}
		file_chooser.destroy();
	}
	
	private void do_save(bool as=false) {
		SourceLabel l = ((SourceLabel) sources.get_tab_label(get_source().get_parent()));
		
		if (l.file() == null || as) {
			var file_chooser = new FileChooserDialog(lang.get("dialog_save"), this, FileChooserAction.SAVE, "_Cancel", ResponseType.CANCEL, "_Save", ResponseType.ACCEPT);
			if (file_chooser.run() == ResponseType.ACCEPT)// change the label from "new x" to actual file
				l.set_file(file_chooser.get_filename());
			else {
				file_chooser.destroy();
				return;
			}
			file_chooser.destroy();
		}
		try {
			set_contents(l.file(), get_source().buffer.text);
		}
		catch (FileError e) {
			errorMsg(e.message);
		}
	}
	
	private void errorMsg(string err) {
		MessageDialog msg = new MessageDialog(this, DialogFlags.MODAL, MessageType.ERROR, ButtonsType.OK, err);
		msg.response.connect((response_id) => msg.destroy());
		msg.show();
	}
	
	private async void update_check() {
		try {
			Dictionary update = read_properties(File.new_for_uri("https://etk2000.com/progs/v4vala.ver"), true);
			
			double version = double.parse(update.get_or_default("version",  "-1"));
			stdout.printf("update check found version %.2f\n", version);
			if (version > VERSION) {// we found an update!
				MessageDialog msg = new MessageDialog(this, DialogFlags.MODAL, MessageType.INFO, ButtonsType.YES_NO, lang.get("update").replace("\\n", "\n").replace("%f", "%.2f").printf(version));
				msg.response.connect((response_id) => {
					msg.destroy();
					
					switch (response_id) {
						case ResponseType.YES:
							string zip = get_tmp_dir() + "/v4vala_update.zip";
							File downloaded = File.new_for_path(zip);
							if (downloaded.query_exists()) {
								try { downloaded.delete(); }
								catch (Error e) {}// delete the file if it already exists
							}
							
							try {
								// download update zip
								File.new_for_uri(update.get_or_default("url", "https://etk2000.com/progs/v4vala.zip")).copy(downloaded, FileCopyFlags.OVERWRITE, null, null);
								
								// create a folder to unzip into
								File.new_for_path(get_current_dir() + "/update").make_directory();
								
								// unzip the downloaded file
								var archive = new Archive.Read();
								archive.support_format_all();
								archive.open_filename(zip, 10240);
								uint8[] buffer = new uint8[4096];
								FileOutputStream fos;
								unowned Archive.Entry entry;
								while (archive.next_header(out entry) == Archive.Result.OK) {
									fos = File.new_for_path(get_current_dir() + "/update/" + entry.pathname()).replace(null, false, FileCreateFlags.NONE);
									while (archive.read_data(buffer, 4096) != 0)
										fos.write(buffer);
								}
								
								// TODO: overwrite the currently running IDE with the newly downloded one
							}
							catch (Error e) {
								errorMsg("Failed to download update:\n" + e.message);
								
								try { downloaded.delete(); }
								catch (Error e) {}
							}
							break;
					}
				});
				msg.show();
			}
			
		}		
		catch (Error e) {
			stderr.printf("Failed to check for update: %s\n", e.message);
		}
	}
	
	private static Dictionary read_properties(File file, bool throwErrors) throws Error{
		Dictionary res = new Dictionary();
		try {
			DataInputStream dis = new DataInputStream(file.read());
			string line;
			int i;
			// read line-by-line and parse lines containing '='
			while ((line = dis.read_line(null)) != null) {
				if ((i = line.index_of_char('=')) != -1)
					res.put(line.substring(0, i).strip(), line.substring(i + 1).strip());
			}
		}
		catch (Error e) {
			if (throwErrors)
				throw e;
		}
		return res;
	}
}