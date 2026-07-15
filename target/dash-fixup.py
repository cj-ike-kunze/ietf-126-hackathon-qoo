#!/usr/bin/env python3
"""
Makes ffmpeg's dash-muxer output compatible with godash's (uccmisl/godash)
MPD template handling, which is simpler than the DASH spec allows:

- It never substitutes the "$RepresentationID$" macro in SegmentTemplate
  attributes (confirmed: no such substitution anywhere in its source) — it
  expects each Representation's own template to already contain literal,
  resolved filenames.
- For init segments, it always reads a SegmentTemplate at the AdaptationSet
  level (GetFullStreamHeader, mpdParsing.go), regardless of content type.
- For media (numbered) segments it reads the Representation-level template
  for video but the AdaptationSet-level one for audio (GetNextSegment,
  mpdParsing.go) — an inconsistency in godash itself, not something we can
  paper over from one side only.

So: resolve "$RepresentationID$" to each Representation's own literal id
in its own SegmentTemplate (fixes video + gives audio a correct template),
then additionally copy the first Representation's now-resolved template up
to the AdaptationSet level in each AdaptationSet (fixes init-segment lookup
for both, and audio's AdaptationSet-level media lookup since there's only
one audio Representation anyway).
"""
import re
import sys

path = sys.argv[1]
with open(path) as f:
    manifest = f.read()

adaptation_set_re = re.compile(r"(<AdaptationSet\b[^>]*>)(.*?)(</AdaptationSet>)", re.DOTALL)
representation_re = re.compile(r'(<Representation\b[^>]*\bid="([^"]+)"[^>]*>)(.*?)(</Representation>)', re.DOTALL)
segment_template_re = re.compile(r"<SegmentTemplate\b.*?(?:/>|</SegmentTemplate>)", re.DOTALL)


def resolve_representation(match):
    open_tag, rep_id, body, close_tag = match.groups()
    body = body.replace("$RepresentationID$", rep_id)
    return open_tag + body + close_tag


def fixup_adaptation_set(match):
    open_tag, body, close_tag = match.groups()
    body = representation_re.sub(resolve_representation, body)

    templates = segment_template_re.findall(body)
    if not templates:
        return open_tag + body + close_tag

    hoisted = templates[0]
    return open_tag + "\n\t\t\t" + hoisted + body + close_tag


manifest = adaptation_set_re.sub(fixup_adaptation_set, manifest)

with open(path, "w") as f:
    f.write(manifest)
