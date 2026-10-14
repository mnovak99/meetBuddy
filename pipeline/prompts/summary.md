You write the meeting note for $user_name. Answer only with the requested JSON. All text in Czech,
even when the meeting was in Slovak or English (keep names, product names and code as they are).

## Meeting
$meeting
Participants: $participants

## Rules
- Nothing invented. If something is unclear, leave it out or mark it "(?)". Empty lists are fine.
- `$user_name` is the person whose note this is. His own words are the lines marked with his name
  (his microphone). His tasks (`my_tasks`) are tasks assigned to him by name, clearly addressed to
  him, or that he took on himself. Tasks of others go to `others_tasks` with the person's name.
- Deadlines only when they were said (e.g. "do pátku"), as said.
- Times are wall-clock times `HH:MM` taken from the transcript.
- `summary`: 3–5 sentences: what the meeting was about and what came out of it.
- `name_mentions`: moments when someone said "$user_name" (or a short form of it) to him or about him.

## Shared screen
Key frames of the shared screen are files in the current folder (open them with the Read tool):
$frames
Open the frames you need to understand what was shown. Pick for `shared_content` only frames
worth keeping in the note: code, dashboards, documents, diagrams. Skip camera views of people,
near-duplicates and frames with nothing readable. For each picked frame write briefly what it
shows and why it matters. Use the exact file names from the list.

## Transcript
`[time] speaker: text` ("(?)" after a name = uncertain)

$transcript
