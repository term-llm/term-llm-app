import Foundation
import ComputerUseCore

/// Notes printed before the first state of an app, once per agent session.
public struct Instructions: Sendable {
    public static let tag = "app_notes"
    public static let browserNote = "browser"
    // The Numbers file ships and is never printed.
    public static let never: Set<String> = ["com.apple.iwork.numbers"]
    // Each prefix also covers beta, nightly and test builds.
    public static let browsers = ["ai.perplexity.comet", "app.floorp.floorp", "app.zen-browser.zen", "com.apple.safari", "com.brave.browser", "com.google.chrome", "com.microsoft.edgemac", "com.operasoftware.opera", "com.vivaldi.vivaldi", "company.thebrowser.browser", "company.thebrowser.dia", "io.gitlab.librewolf-community.librewolf", "net.imput.helium", "net.librewolf.librewolf", "net.waterfox.", "org.chromium.chromium", "org.mozilla.firefox", "org.mozilla.nightly"]
    public var stateDirectory: @Sendable () -> URL
    public init(stateDirectory: @escaping @Sendable () -> URL = { Paths.stateDirectory() }) {
        self.stateDirectory = stateDirectory
    }
    public func personalDirectory() -> URL { stateDirectory().appendingPathComponent("instructions") }
    public func note(_ bundleID: String) -> String? {
        let key = bundleID.lowercased()
        let names = Self.browsers.contains(where: key.hasPrefix) ? [key, Self.browserNote] : [key]
        let files = (try? FileManager.default.contentsOfDirectory(at: personalDirectory(), includingPropertiesForKeys: nil)) ?? []
        for name in names {
            if let file = files.first(where: { $0.pathExtension == "md" && $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                // An unreadable or empty personal file replaces the built-in too;
                // a note that cannot be read never fails a state read.
                guard let text = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return text
            }
        }
        for name in names { if let text = Self.builtIn[name] { return text } }
        return nil
    }
    public func prefix(agent: AgentSession, bundleID: String) -> String? {
        let key = bundleID.lowercased()
        guard !Self.never.contains(key), !agent.instructed.contains(key), let text = note(key) else { return nil }
        // Filesystem work and the injected directory callback stay outside the
        // agent lock. Another app worker may claim this note while it is read.
        let claimed = agent.withState {
            guard !agent.instructed.contains(key) else { return false }
            agent.instructed.insert(key)
            return true
        }
        guard claimed else { return nil }
        return "<\(Self.tag)>\n\(text)\n</\(Self.tag)>\n"
    }
    public static let builtIn: [String: String] = [
        "browser": #"""
## Browser use

Open a new tab when you go to a new website or start a separate web task. Stay in the current tab only when the person asked to continue there, or when the page that is open is clearly the right place to go on with the same work.
"""#,
        "com.apple.music": #"""
## Music

### Search

To search for music, click the Search row in the sidebar, then use `set_value` on the search text field. The search starts by itself. If no results show, run `get_app_state` again and see whether they have loaded.

If the search field is not there, scroll the sidebar to the very top. The `filterField` (a search field that appears after a click on `filterBtn`) only filters the view that is open. It does not search the library or the catalog.

To find a playlist, search (with "Your Library" selected in the results) or scroll down in the sidebar.

### Moving around

Scroll an element with its `Scroll Up` or `Scroll Down` action, through `perform_secondary_action`. To scroll further, run the action several times in one `&&` chain.

After you select a sidebar item you may land one level deeper than you expected. `backBtn` takes you back to the top level.

### Playback

Double-click a track to play it: `click` with `--click_count 2`.

Queue a track ("Playing Next") through its "More" button: choose "Play Next" or "Play Last". No "More" button: right-click the track.
"""#,
        "com.apple.screencontinuity": #"""
## iPhone Mirroring

Keys that work here, each with `press_key`:

- `super+1` Home Screen
- `super+2` App Switcher
- `super+3` Spotlight

Scroll with `scroll`, never with `drag`.

To open an app on the home screen, click the middle of its icon, not the name under it.
"""#,
        "com.apple.clock": #"""
## Clock

What you can do for the person in Clock:

- World Clock: add a city or remove one.
- Timer: start, pause, resume, cancel.
- Stopwatch: start, stop, lap, reset.
- Add, edit, remove, switch on or switch off alarms.

### Add a city to the World Clock

1. Click the toolbar tab "World Clock" unless it is open already.
2. Find the clocks that exist now: look at the ID of each container that has exactly one text child. Ignore the places listed under the heading "world map". That list is not updated when a clock is removed.
3. If the city is missing, click the toolbar menu button with the description "Add a clock".
4. A sheet for searching opens. Search by setting the value of its text field with `set_value`. A click on the text of a city adds it and closes the sheet.

### Start a timer

1. Click the toolbar tab "Timer" ("Timers" in British English) unless it is open already.
2. Find out the state of the timer before anything else.
3. **Stopped**: go on. **Running** or **Paused**: tell the person that a timer exists, and offer to cancel it and start the new one.
4. Split the wanted time into **hours** (0 to 23), **minutes** (0 to 59) and **seconds** (0 to 59). "90 seconds" is 0 hours, 1 minute, 30 seconds. "3600 seconds" is 1 hour, 0 minutes, 0 seconds. Refuse a time above 23:59:59: Clock cannot run such a timer.
5. Find the container with the identifier "TimePicker". Its three slider children are hours, minutes and seconds. Set them in that order.
6. For each of the three sliders:
    1. Click it to give it focus.
    2. Type the number with `type_text`. Never use `set_value` here. At most 2 digits: hours up to 23, minutes and seconds up to 59.
7. Press "Start" (a button, found by its description).

### Start a stopwatch

1. Click the toolbar tab "Stopwatch" unless it is open already.
2. Find out the state of the stopwatch.
3. **Running** (the `StartStopButton` says "Stop"): offer to stop or restart it. **Stopped** (it says "Start"): press the Start button.

### Make an alarm

1. Click the toolbar tab "Alarm" unless it is open already.
2. Click the toolbar menu button with the description "Add an alarm".
3. A sheet opens:
    - Time: use `set_value` on the date time area, in the same format as its current Value.
    - Leave the AM/PM radio button alone. It follows the date time area.
    - Repeat days: seven toggle buttons with the values S, M, T, W, T, F, S, one per day of the week. A toggle that is on means the alarm repeats on that day.
    - There are also elements for the label, the sound and snoozing.
4. Finish with the "Save" button.
"""#,
        "com.apple.iwork.numbers": #"""
## Numbers

### Editing cells

Select a cell with `click` before you edit it. One click for an empty cell, or to add to what is in it. Three clicks (`--click_count 3`) to replace what is in it.

To change a cell, chain two commands with `&&`: the `click` that selects the cell (one or three clicks), then `type_text` with the new value.

A whole row in one `type_text` call, with a tab between the cells, is a good way to enter many values. Never enter several rows, or several formulas, in one `type_text` call: it fails.

Notes:

- A cell with focus may show a "text entry area" with extra formatting, such as Markdown bold in table headers. Ignore it.
- A cell value is saved at once. Press `Return` only when you are done with the whole spreadsheet.
- A checkbox cell takes 0 (off) or 1 (on) as typed text.
"""#,
        "com.spotify.client": #"""
## Spotify

### Playback

After a click that starts playback, Spotify shows the old state for a moment: the track may still look paused, or the old track may still be shown. Do not act again. First run `get_app_state` once more and see whether the click worked. Do not sleep: the state is up to date by the time you read again.

### Search

Check that the search field has focus before you press `Return`. With the focus somewhere else, `Return` can change what is playing.

### Moving around

Much of what Spotify shows comes from the network, so an answer can take a moment. A search can say "no results" for an instant. Run `get_app_state` again before you change your plan.

Note: a link taken from the Spotify app works only after it is rewritten as a normal web link: `open.spotify.com` in place of `xpui.app.spotify.com`. Use only links that stand word for word in the state above. An ID is valid only with its own type: the ID of an "album" URL cannot be put into a "track" URL.
"""#,
        "com.tinyspeck.slackmacgap": #"""
## Slack

When no text field has focus, Slack puts typed text into the message composer. Before you press `Return`, check that the field you mean has focus, or you may send a message by accident.

Write into the message composer with `set_value`, not `type_text`: a text of several lines then cannot be sent by accident. `set_value` writes Markdown marks as plain characters. To turn them into formatting afterwards, press `super+shift+f`.

A text that contains a newline:

- `set_value` adds a new line and does not send.
- `type_text` **sends** the message.

If you must make a new line with `type_text` or `press_key`: each person chooses in Slack whether `Return` or `shift+Return` sends. The text from `get_app_state` tells you which. A button below the composer carries the hint "(key combination) to add a new line". The other combination sends. The hint is there only when the composer holds 3 or more characters, and only in the composer under a channel or a direct message, not in thread replies or edits.

If the text from `get_app_state` on Slack does not behave as expected, trust the screenshot.
"""#,
        "notion.id": #"""
## Notion

### Editing a page

A page is made of blocks. A block can be selected. Press `Return` to edit the text of the selected block.

A new page has an empty title that shows "New page". Type the title, then press `Return` to start the body. To put the cursor into the title, click the text element inside the heading.

Enter one line at a time: `type_text` with the line, then `press_key` with `Return`, chained with `&&`.

Format with Markdown marks. Two of them differ from Markdown: ">" starts a toggle list, and "|" starts a quote.

### Lists

`Return` at the end of a list item starts the next item, with its marker already there. Type only the text of the item, never the marker. To leave the list, press `Return` on an empty item.

### Select all

What `super+a` selects depends on where the cursor is:

- In an empty block: every block of the page.
- In a block with text: the text of that block.
- When the whole text of a block is selected already: every block of the page.

### Placeholders

An empty element shows a placeholder:

- Page title: "New page"
- List item: "List"
- To-do item: "To-do"
- Empty line: a text that starts with "Write,"

It goes away when you type. Never try to select or delete it.

### Code and quote blocks

In a code block `Return` makes a new line inside the block, and `shift+Return` makes one outside it. A quote block is the other way round: `Return` goes outside, `shift+Return` stays inside.

### Moving the cursor

To the top or the bottom: give the page text focus, press `super+a` twice to select the whole page, press `Up` or `Down`, then `Return` to edit the first or the last block.

To one block: press `super+a` twice, then click that block once.

Or search: press `super+f`, type the words, then press `Escape`. The match is now the selected text.
"""#,
    ]
}
