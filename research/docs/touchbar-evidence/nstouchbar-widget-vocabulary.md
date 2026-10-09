# macOS NSTouchBar — Complete Widget Vocabulary
# Research document for the touchbar-evidence project
# Date: 2026-08-25
# Source: Apple developer.apple.com documentation (fetched 2026-08-25)

## 1. NSTouchBarItem Subclasses (10 total)

These are the concrete item classes AppKit provides. Each renders a specific
UI element in the Touch Bar.

### 1.1 NSCustomTouchBarItem
- UI: Any NSView or NSViewController (fully custom)
- The most flexible item — hosts any AppKit control or custom view
- Supports: custom drawing, animation, gesture recognizers, direct NSTouch handling
- Content is app-provided; the class is system-provided

### 1.2 NSButtonTouchBarItem (macOS 10.15+)
- UI: Button (title + image + bezelColor)
- Convenience wrappers around NSButton, correctly sized for Touch Bar
- System class, app-configured

### 1.3 NSSliderTouchBarItem
- UI: Slider (value in a range, with optional label and min/max accessories)
- Wraps NSSlider with Touch-Bar-optimized sizing
- System class, app-configured

### 1.4 NSColorPickerTouchBarItem
- UI: System color picker (color wheel / swatches)
- Factory methods: colorPicker, textColorPicker, strokeColorPicker
- Configurable: colorList, allowedColorSpaces, showsAlpha
- System-provided picker UI; app supplies color list & target

### 1.5 NSCandidateListTouchBarItem
- UI: Candidate list (textual suggestions for current text view)
- Used for predictive text / spell-check completions
- Works with NSSpellChecker.requestCandidates(...)
- Collapsible behavior; can pull candidates from text-input providers
- System-provided UI; app supplies candidates via delegate

### 1.6 NSSharingServicePickerTouchBarItem
- UI: Sharing picker (system share sheet UI)
- Shows list of objects eligible for sharing
- Collapsed representation: button with optional buttonImage/buttonTitle
- System-provided share sheet; app supplies items via delegate

### 1.7 NSPopoverTouchBarItem
- UI: Two-state popover (collapsed button → expands to nested NSTouchBar)
- Collapsed: button with image/label/custom view
- Expanded: nested NSTouchBar (popoverTouchBar)
- Optional: pressAndHoldTouchBar, chevron, close button
- System class; inner bar is app-provided

### 1.8 NSGroupTouchBarItem
- UI: Group/container (nested NSTouchBar of other items)
- Visually groups items together
- Supports: equal widths, preferred item width, layout direction
- Special variant: +alertStyleGroupItemWithIdentifier: (alert styling)
- System class; contained items are app-provided

### 1.9 NSPickerTouchBarItem (macOS 10.15+)
- UI: Picker control with multiple options (tab-group-like)
- Options can be labels and/or images
- SelectionMode: single or multiple
- ControlRepresentation: display style options
- Collapsed representation can use image or label
- System class, app-configured

### 1.10 NSStepperTouchBarItem (macOS 10.15+)
- UI: Stepper control (increment/decrement a value)
- Current value shown via formatter (as text) or drawingHandler (as image)
- Has min/max/increment
- System class, app-configured

---

## 2. NSScrubber (the signature Touch Bar control)

Not an NSTouchBarItem subclass, but hosted inside NSCustomTouchBarItem.
This is the iconic horizontal scrolling picker seen in Apple apps.

### NSScrubber
- Horizontally-oriented, customizable item-picker
- Collection-view-like API: data source, delegate, layout, reuse queue
- Scrolling modes: fixed or free
- Alignment: leading, center, trailing
- Selection: continuous or deliberate
- Optional arrow buttons
- Selection overlay/background styles

### Built-in scrubber item views (NSScrubberItemView subclasses):
- NSScrubberTextItemView — cell showing text (a title)
- NSScrubberImageItemView — cell showing an image
- Custom subclasses — fully custom cells

### Built-in scrubber layouts (NSScrubberLayout subclasses):
- NSScrubberFlowLayout — fixed-size items in a flow
- NSScrubberProportionalLayout — items sized proportionally to content
- Custom subclasses — custom layout

---

## 3. Standard Built-in Item Identifiers (11)

These are reserved identifiers for NSTouchBar.defaultItemIdentifiers. The
system automatically instantiates and configures the corresponding item.

| Identifier | What it renders |
|------------|-----------------|
| candidateList | Candidate-list item (auto-inserted for text views) |
| characterPicker | Character picker (Emoji/special characters) |
| textFormat | Group of text-formatting controls (bold/italic/underline) |
| textAlignment | Text alignment control (left/center/right/justified) |
| textColorPicker | Text-color picker (uses NSColorPickerTouchBarItem) |
| textList | Text list style control (bulleted/numbered) |
| textStyle | Text style control (heading levels, paragraph style) |
| fixedSpaceSmall | Small fixed-width space between items |
| fixedSpaceLarge | Large fixed-width space between items |
| flexibleSpace | Flexible space (expands to fill width) |
| otherItemsProxy | Proxy slot for nesting items from responder chain bars |

---

## 4. AppKit Controls Placeable in Custom/Popover/Group Items

Because NSCustomTouchBarItem, NSPopoverTouchBarItem (collapsed), and
NSGroupTouchBarItem can host arbitrary NSViews, these standard controls
can be rendered in the Touch Bar:

| Control | UI in Touch Bar |
|---------|-----------------|
| NSButton | Button (title, image, or both; bezelColor) |
| NSSegmentedControl | Segmented control (multi-segment switch / tabs) |
| NSSlider | Slider (trackFillColor) — prefer NSSliderTouchBarItem |
| NSScrubber | Horizontal scrubber/picker (see above) |
| NSImageView | Static image |
| NSTextField / NSTextView | Text (NSTextView gets auto text-styling + predictive text) |
| NSScrollView | Scroll view (useful in popovers) |
| NSStackView | Stack of items (prefer NSGroupTouchBarItem for grouping) |
| Any custom NSView subclass | Fully custom-drawn content + gesture recognizers |

### Supported gesture recognizers:
- NSClickGestureRecognizer
- NSPanGestureRecognizer
- NSPressGestureRecognizer
- NSMagnificationGestureRecognizer (two-finger pinch)

---

## 5. Always-Present System UI (not NSTouchBarItems)

| Element | Description |
|---------|-------------|
| Control Strip | System-supplied, always on right: brightness, volume, Siri. User can hide it. |
| Touch ID sensor | Right of Control Strip; via LocalAuthentication framework |
| Escape key | App can replace via NSTouchBar.escapeKeyReplacementItemIdentifier |

---

## 6. System Template Images (~60+ glyphs)

System-provided, Touch-Bar-only template images for button glyphs.
Auto-adapt to white-point changes and Touch Bar appearance.

### Categories (representative subset):

**Add/create:**
touchBarAddTemplate, touchBarAddDetailTemplate, touchBarNewFolderTemplate,
touchBarComposeTemplate

**Navigation:**
touchBarGoBackTemplate, touchBarGoForwardTemplate, touchBarGoUpTemplate,
touchBarGoDownTemplate

**Media playback:**
touchBarPlayTemplate, touchBarPauseTemplate, touchBarPlayPauseTemplate,
touchBarRewindTemplate, touchBarFastForwardTemplate, touchBarSkipToStartTemplate,
touchBarSkipToEndTemplate, touchBarSkipBackTemplate, touchBarSkipAheadTemplate,
touchBarSkipBack15SecondsTemplate, touchBarSkipAhead30SecondsTemplate,
touchBarRecordStartTemplate, touchBarRecordStopTemplate, touchBarPlayheadTemplate

**Audio:**
touchBarAudioInputTemplate, touchBarAudioInputMuteTemplate,
touchBarAudioOutputMuteTemplate, touchBarAudioOutputVolumeHighTemplate,
touchBarAudioOutputVolumeMediumTemplate, touchBarAudioOutputVolumeLowTemplate,
touchBarAudioOutputVolumeOffTemplate, touchBarVolumeUpTemplate,
touchBarVolumeDownTemplate

**Text editing:**
touchBarTextBoldTemplate, touchBarTextItalicTemplate, touchBarTextUnderlineTemplate,
touchBarTextStrikethroughTemplate, touchBarTextLeftAlignTemplate,
touchBarTextCenterAlignTemplate, touchBarTextRightAlignTemplate,
touchBarTextJustifiedAlignTemplate, touchBarTextListTemplate, touchBarTextBoxTemplate

**Color pickers:**
touchBarColorPickerFill, touchBarColorPickerFont, touchBarColorPickerStroke

**Views/files:**
touchBarFolderTemplate, touchBarFolderCopyToTemplate, touchBarFolderMoveToTemplate,
touchBarListViewTemplate, touchBarIconViewTemplate, touchBarBookmarksTemplate,
touchBarHistoryTemplate, touchBarGetInfoTemplate, touchBarQuickLookTemplate,
touchBarSlideshowTemplate, touchBarSidebarTemplate, touchBarTagIconTemplate,
touchBarSearchTemplate, touchBarRefreshTemplate, touchBarDownloadTemplate,
touchBarMailTemplate, touchBarNewMessageTemplate, touchBarOpenInBrowserTemplate,
touchBarShareTemplate, touchBarEnterFullScreenTemplate, touchBarExitFullScreenTemplate,
touchBarRotateLeftTemplate, touchBarRotateRightTemplate, touchBarAlarmTemplate,
touchBarUserTemplate, touchBarUserAddTemplate, touchBarUserGroupTemplate,
touchBarDeleteTemplate

---

## 7. Custom Item Capabilities

- Any NSView/NSViewController via NSCustomTouchBarItem.view/.viewController
- Custom gesture recognizers (click, pan, press, magnification)
- Direct NSTouch event handling (touchesBegan/Moved/Ended/Cancelled)
- Custom scrubber layouts (subclass NSScrubberLayout)
- Custom scrubber item views (subclass NSScrubberItemView)
- Recursive nesting (popovers/groups inside popovers/groups)
- Custom principal item (centered via principalItemIdentifier)
- Custom Escape key replacement
- User customization palette (items with customizationLabel appear in
  the system's on-screen customization UI for drag in/out/rearrange)

---

## Sources

All fetched from developer.apple.com (Markdown versions) on 2026-08-25:

- NSTouchBar overview:
  https://developer.apple.com/documentation/appkit/nstouchbar
- NSTouchBarItem reference:
  https://developer.apple.com/documentation/appkit/nstouchbaritem
- NSTouchBarItem.Identifier struct:
  https://developer.apple.com/documentation/appkit/nstouchbaritem/identifier-swift.struct
- NSCustomTouchBarItem:
  https://developer.apple.com/documentation/appkit/nscustomtouchbaritem
- NSButtonTouchBarItem:
  https://developer.apple.com/documentation/appkit/nsbuttontouchbaritem
- NSSliderTouchBarItem:
  https://developer.apple.com/documentation/appkit/nsslidertouchbaritem
- NSColorPickerTouchBarItem:
  https://developer.apple.com/documentation/appkit/nscolorpickertouchbaritem
- NSCandidateListTouchBarItem:
  https://developer.apple.com/documentation/appkit/nscandidatelisttouchbaritem
- NSSharingServicePickerTouchBarItem:
  https://developer.apple.com/documentation/appkit/nssharingservicepickertouchbaritem
- NSPopoverTouchBarItem:
  https://developer.apple.com/documentation/appkit/nspopovertouchbaritem
- NSGroupTouchBarItem:
  https://developer.apple.com/documentation/appkit/nsgrouptouchbaritem
- NSPickerTouchBarItem:
  https://developer.apple.com/documentation/appkit/nspickertouchbaritem
- NSStepperTouchBarItem:
  https://developer.apple.com/documentation/appkit/nssteppertouchbaritem
- NSScrubber:
  https://developer.apple.com/documentation/appkit/nsscrubber