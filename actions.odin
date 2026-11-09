package main

// Every command the editor has. One table (ACTION_INFO) describes them all and
// drives the menu bar, the F1 command palette, tooltips and the keybindings.ini
// sections, so adding a command = one enum entry, one table row, one case in
// do_action. The enum order is the order within menus.
//
// The workflow the commands follow:
//   import video / audio -> remove audio -> import the song -> detect bpm ->
//   bpm grid or pattern on it -> prepare patterns -> slice / randomize

Action :: enum {
	// file
	New_Project,
	Open_Project,
	Save_Project,
	Import, // video, audio, the song
	Export,
	Quit,
	// edit
	Undo,
	Redo,
	Duplicate, // clips if any are selected, else the selected layers
	Delete, // a program cut, else clips, else the selected layers
	Remove_Audio, // audio clips: of the selected clips, else on the selected layers, else the ones linked to videos
	Remove_Video,
	Remove_Audio_Layers,
	Remove_Video_Layers,
	Select_All,
	Link,
	Unlink,
	// timeline
	Split,
	Add_Layer,
	Remove_Layer,
	Play, // press twice quickly to stop and return to the checkpoint
	Toggle_Grid,
	// tempo + slicing
	Detect_Bpm, // tempo + first beat from the selected audio clip (else the first one); sets the beat grid
	Tap_Tempo,
	Grid_Here, // put a beat of the grid at the playhead
	Pattern_Editor,
	Apply_Pattern, // loop the current pattern over the selected segment, else everything
	Beat_Split, // cut on the grid: the selected segment, else the whole project
	Mark, // add a cut at the playhead (snapped); works during playback
	Slice_At_Cuts, // slice the real clips (selected, else all) at every program cut
	Copy_Cuts, // copy the cuts of the selected program range
	Paste_Cuts, // paste them at the playhead
	Repeat_Range, // repeat the selected range's cuts until the end of the project
	Loop_Playback, // loop playback over the selected program range
	Clear_Cuts,
	Randomize, // with the options of the Randomize window
	Randomize_Options,
	// not in the menus or the palette: keys only
	To_Checkpoint, // stop and return to the checkpoint (last click on the ruler / empty timeline)
	Go_Start,
	Go_End,
	Step_Back, // one frame
	Step_Forward,
	Stretch, // hold while dragging a clip edge to change speed instead of trimming
	No_Snap, // hold while dragging/scrubbing to ignore the grid
	Tool_Select,
	Tool_Razor,
	Tool_Hand,
	Tool_Zoom,
	Layer_1, // show the Nth video layer: from now when playing, else on the selected segment
	Layer_2,
	Layer_3,
	Layer_4,
	Layer_5,
	Layer_6,
	Layer_7,
	Layer_8,
	Layer_9,
	// app
	Command_Palette,
	Reload_Keys,
}

Action_Info :: struct {
	name:    string, // shown in menus / palette / tooltips: short
	section: string, // [section] in keybindings.ini
	group:   string, // menu bar menu; "" = not in the menu bar
	sep:     bool, // separator before it in the menu
	hidden:  bool, // not in the palette (keys still work)
}

ACTION_INFO := [Action]Action_Info {
	.New_Project         = {"New project", "file", "File", false, false},
	.Open_Project        = {"Open...", "file", "File", false, false},
	.Save_Project        = {"Save", "file", "File", false, false},
	.Import              = {"Import media...", "file", "File", true, false},
	.Export              = {"Export...", "file", "File", false, false},
	.Quit                = {"Quit", "file", "File", true, false},
	.Undo                = {"Undo", "edit", "Edit", false, false},
	.Redo                = {"Redo", "edit", "Edit", false, false},
	.Duplicate           = {"Duplicate", "edit", "Edit", true, false},
	.Delete              = {"Delete", "edit", "Edit", false, false},
	.Remove_Audio        = {"Remove audio", "edit", "Edit", true, false},
	.Remove_Video        = {"Remove video", "edit", "Edit", false, false},
	.Remove_Audio_Layers = {"Remove audio layers", "edit", "Edit", false, false},
	.Remove_Video_Layers = {"Remove video layers", "edit", "Edit", false, false},
	.Select_All          = {"Select all", "edit", "Edit", true, false},
	.Link                = {"Link", "edit", "Edit", false, false},
	.Unlink              = {"Unlink", "edit", "Edit", false, false},
	.Split               = {"Split at playhead", "timeline", "Timeline", false, false},
	.Add_Layer           = {"Add layer", "timeline", "Timeline", true, false},
	.Remove_Layer        = {"Remove layers", "timeline", "Timeline", false, false},
	.Play                = {"Play / pause", "timeline", "Timeline", true, false},
	.Toggle_Grid         = {"Snap to grid", "timeline", "Timeline", false, false},
	.Detect_Bpm          = {"Detect bpm", "program", "Tempo", false, false},
	.Tap_Tempo           = {"Tap tempo", "program", "Tempo", false, false},
	.Grid_Here           = {"Beat at playhead", "program", "Tempo", false, false},
	.Pattern_Editor      = {"Patterns...", "program", "Slice", false, false},
	.Apply_Pattern       = {"Apply pattern", "program", "Slice", false, false},
	.Beat_Split          = {"Slice on grid", "program", "Slice", false, false},
	.Mark                = {"Cut at playhead", "program", "Slice", false, false},
	.Slice_At_Cuts       = {"Slice clips at cuts", "program", "Slice", false, false},
	.Copy_Cuts           = {"Copy cuts", "program", "Slice", true, false},
	.Paste_Cuts          = {"Paste cuts", "program", "Slice", false, false},
	.Repeat_Range        = {"Repeat range", "program", "Slice", false, false},
	.Loop_Playback       = {"Loop range playback", "program", "Slice", false, false},
	.Clear_Cuts          = {"Clear cuts", "program", "Slice", false, false},
	.Randomize           = {"Randomize", "program", "Slice", true, false},
	.Randomize_Options   = {"Randomize options...", "program", "Slice", false, false},
	.To_Checkpoint       = {"Back to checkpoint", "timeline", "", false, true},
	.Go_Start            = {"Go to start", "timeline", "", false, true},
	.Go_End              = {"Go to end", "timeline", "", false, true},
	.Step_Back           = {"Back one frame", "timeline", "", false, true},
	.Step_Forward        = {"Forward one frame", "timeline", "", false, true},
	.Stretch             = {"Stretch (hold)", "timeline", "", false, true},
	.No_Snap             = {"No snapping (hold)", "timeline", "", false, true},
	.Tool_Select         = {"Selection tool", "tools", "", false, true},
	.Tool_Razor          = {"Razor tool", "tools", "", false, true},
	.Tool_Hand           = {"Hand tool", "tools", "", false, true},
	.Tool_Zoom           = {"Zoom tool", "tools", "", false, true},
	.Layer_1             = {"Show layer 1", "program", "", false, true},
	.Layer_2             = {"Show layer 2", "program", "", false, true},
	.Layer_3             = {"Show layer 3", "program", "", false, true},
	.Layer_4             = {"Show layer 4", "program", "", false, true},
	.Layer_5             = {"Show layer 5", "program", "", false, true},
	.Layer_6             = {"Show layer 6", "program", "", false, true},
	.Layer_7             = {"Show layer 7", "program", "", false, true},
	.Layer_8             = {"Show layer 8", "program", "", false, true},
	.Layer_9             = {"Show layer 9", "program", "", false, true},
	.Command_Palette     = {"Commands", "app", "", false, false},
	.Reload_Keys         = {"Reload keys", "app", "Help", false, false},
}

MENU_GROUPS :: [?]string{"File", "Edit", "Timeline", "Tempo", "Slice", "Help"}
