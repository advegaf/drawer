# Changelog

## 1.0.3

- **The hover card fits what it says.** It was one fixed width for every cell,
  which left 157pt for a title and a note, so Screen Recording beside its clock
  drew as "Screen Recordi..." and the timer got clipped as well. The card is
  measured now, never narrower than it was and never wider than a cap, and the
  clock keeps one width from 0:00 into double digit minutes.

## 1.0.2

- **Screen Recording stops when you tell it to.** A click asks for a state now
  rather than flipping whatever the cell last showed, so a ring that had
  drifted out of step with the recording corrects itself instead of starting a
  second one. While it records, the card counts up.
- **Focus is gone.** Setting a Focus mode needs an entitlement only Apple
  issues: the API exists, and the daemon refuses anyone who is not Apple. The
  cell that shipped could not have worked, and one that opens Control Center
  for you is not worth a cell. If you had it pinned it disappears on its own.
  To switch a Focus from the drawer, make a Shortcut with Apple's Set Focus
  action and pin the shortcut.

## 1.0.1

Three actions did nothing, and two of them were the same bug: a fire action
folds the drawer before it runs, and a folded drawer is drawn at zero opacity,
so Clean Keyboard and Force Quit were reporting their failures into a cell
nobody could see. A failed action brings the drawer back now.

- Force Quit force quits the app you were in. It used to open Apple's Force
  Quit window and quit nothing. It arms first, like Empty Trash.
- Screen Recording asks for the permission it needs, and says so when it is
  refused, instead of showing a cell that reads On with nothing recording.
- The Accessibility prompt is shown once and never again. After that Drawer
  opens the right pane in System Settings. If Drawer is already listed there
  and still says it has no permission, switch that row off and on again: macOS
  grants this to a signed copy rather than to a name.
- A secondary click on the microphone picks the input, the way Wi-Fi,
  Bluetooth and Volume already did.
- Eleven more actions: Dock magnification, Dock recents, minimise into icon,
  click wallpaper to clear the screen, the Finder's path bar and status bar,
  all file extensions, the screenshot thumbnail, seconds on the clock, True
  Tone, and the microphone's input level.

## 1.0.0

The first release, and the first build that leaves the machine it was written
on: signed with a Developer ID, notarized, and installed by dragging it out of
a disk image.

### The drawer

- A pill welded to the right or left screen edge that unfolds on hover into a
  column of round cells, and folds away when the pointer leaves.
- Shift Command Space opens it from anywhere and holds the keyboard while it
  is open: arrows move, Return activates, Escape closes.
- Three finishes (Follow macOS, OLED, Light), an accent colour, three cell
  sizes, optional labels.
- Hover cards that name the cell and show what it is doing, with volume and
  brightness draggable inside the card.

### What a cell can be

- An app, an Apple Shortcut, or one of fifty-one actions.
- Wi-Fi, Bluetooth, dark mode, Night Shift, Stage Manager, mute, volume,
  brightness, keep awake, lock screen, sleep, empty trash, three screenshots,
  Mission Control, show desktop and the screen saver.
- Quit App, Hide Others, Force Quit, Sleep Displays, Eject Disks, Restart,
  Shut Down, Log Out.
- Desktop Icons, Hidden Files, Hide Dock, Hide Menu Bar, Battery Percent,
  Relaunch Finder, Relaunch Dock.
- Play or Pause, Next Track, Previous Track, Mute Mic, Clean Keyboard, Paste
  as Text, Screen Recording.
- A secondary click on Wi-Fi, Bluetooth or Volume picks a network, a paired
  device or an output rather than toggling.
- Eject, Restart, Shut Down and Log Out arm on the first click and fire on the
  second.

### Settings

- A sidebar beside a page of cards: Items, Appearance, General.
- A live preview of your own drawer that you drag items onto and reorder
  inside, and a searchable library of everything you can pin.
- Hovering an added library row turns it into a red Remove.
- A chord recorder, a Dock or menu bar presence switch, and open at login.

### Who wrote it

- Built by Angel Vega and Daniel JW.
- The notch design the drawer's shape came from is Vinz's.

### The first run

- A guide that shows once per install and explains the four things worth
  knowing, reachable again from the menu bar item.
