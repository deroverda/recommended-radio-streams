---
name: Submit a station
about: Add a station to the greatest radio list on the internet
title: ''
labels: enhancement
assignees: deroverda

---

name: 🎵 Submit a new station
description: Add a station to the greatest radio list on the internet
title: "[Station Submission] "
labels: ["submission", "needs-review"]
body:
  - type: markdown
    attributes:
      value: |
        Thank you for making this list even more legendary ❤️
        Please fill this out and I'll add it within 24h (usually faster).

  - type: input
    id: station-name
    attributes:
      label: Station Name
      description: Exact name as it should appear
      placeholder: ex. FIP
    validations:
      required: true

  - type: input
    id: website
    attributes:
      label: Official Website / Web Player URL
      description: Preferred. Direct stream URLs accepted only if no website exists.
      placeholder: https://www.radiofrance.fr/fip
    validations:
      required: true

  - type: textarea
    id: description
    attributes:
      label: One-sentence vibe check
      description: Why is this station good? 
      placeholder: ex. The pioneer of independent internet radio. Famous for ambient, downtempo, and "Groove Salad" vibes.
    validations:
      required: true

  - type: dropdown
    id: genre
    attributes:
      label: Main Genre(s) – pick up to 3
      multiple: true
      options:
        - Chill / Ambient / Lo-Fi
        - Electronic / Dance
        - Jazz / Soul / Funk
        - Rock / Indie / Alternative
        - Classical / Instrumental
        - Metal / Extreme
        - Hip-Hop / R&B
        - Reggae / Dub / Afro
        - World / Regional
        - Vaporwave / Future Funk
        - Video Game / Chiptune
        - HiRes / Lossless
        - Experimental / Weird
        - Other (specify in description)

  - type: checkboxes
    id: confirmation
    attributes:
      label: Final check
      options:
        - label: I have tested the stream in the last 24 hours and it works globally (no geo-block)
          required: true
        - label: This station is human-curated (not AI-generated slop)
          required: true

  - type: markdown
    attributes:
      value: |
        That’s it. Hit submit and go touch grass. I’ll do the rest.
        – deroverda
