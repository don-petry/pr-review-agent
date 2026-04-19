---
name: kids-calendar
description: Plan the Petry/Bowen family schedule for an upcoming school year or summer break. Pulls calendars, identifies constraints, proposes a schedule for David's visits, grandparent visits, Toby/Tide's Aunt Kim trip, and DJ/Rachel getaway weekends, then creates Google Calendar events on approval.
argument-hint: [planning-period]
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash, Agent, AskUserQuestion, mcp__921cf00d-28fd-4f00-91cb-2b37c865b8c8__list_calendars, mcp__921cf00d-28fd-4f00-91cb-2b37c865b8c8__list_events, mcp__921cf00d-28fd-4f00-91cb-2b37c865b8c8__create_event, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__search_files, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__read_file_content
---

# Kids Calendar Planner

Plan the Petry/Bowen family schedule for a school year or summer break cycle. Gathers constraints from Google Calendar, asks targeted questions, produces a conflict-aware schedule proposal, then creates calendar events on approval.

---

## Workflow Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    /kids-calendar [period]                       │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                    ┌───────▼────────┐
                    │  STEP 1        │
                    │  Confirm       │
                    │  Planning      │
                    │  Period        │
                    │  (school year  │
                    │   or summer)   │
                    └───────┬────────┘
                            │
          ┌─────────────────▼──────────────────┐
          │  STEP 2 — Parallel Calendar Fetch   │
          │  DJ · Rachel · Davie in Dad's ·     │
          │  Charley Ann · Bowen Kids ·         │
          │  2809 Family · Erika (if needed)    │
          └─────────────────┬──────────────────┘
                            │
                    ┌───────▼────────┐
                    │  STEP 2b       │
                    │  Anchor fixed  │
                    │  events first: │
                    │  🏕 Winshape   │
                    │  ✈ JAX Trip    │
                    │  🍯 Honey Pull │
                    │  🎄 Christmas  │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │  STEP 3        │
                    │  Ask targeted  │
                    │  questions:    │
                    │  David visits  │
                    │  Babbi & GE    │
                    │  Getaways      │
                    │  Aunt Kricket  │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │  STEP 4        │
                    │  Build         │
                    │  conflict-free │
                    │  schedule      │
                    │  (flag gaps    │
                    │  >5wks David)  │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │  STEP 5        │
                    │  Present       │──── Changes requested? ──┐
                    │  proposal for  │                          │
                    │  review        │◄─────────────────────────┘
                    └───────┬────────┘     (STEP 6: Refine)
                     Approved│
                    ┌───────▼────────┐
                    │  STEP 7        │
                    │  Create Google │
                    │  Calendar      │
                    │  events        │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │  OUTPUT        │
                    │  ✅ Events     │
                    │  created +     │
                    │  📋 Action     │
                    │  item list     │
                    └────────────────┘
```

**Priority stack when building the schedule (Step 4):**
```
LOCK FIRST (immovable)
  └── Camp Winshape dates
  └── Toby & Tide → Aunt Kim, Jacksonville (every Thanksgiving)
  └── Honey Pull Week (July 4th week)
  └── David's Christmas block (alternates by year)
  └── David's Thanksgiving block (even years at DJ's)

FLAG & CONFIRM (flexible with notice)
  └── Spring getaway weekends → check beekeeping season first
  └── David visit windows → confirm with Naomi 30 days out
  └── Tide work shifts → 2+ weeks notice to request off
  └── Erika visit weekends → query her calendar first

FILL REMAINING WINDOWS
  └── Additional David visits (goal: 1+/month, max time)
  └── Babbi & GE visits (Panama City or Birmingham)
  └── DJ & Rachel getaway weekends
  └── Aunt Kricket (Erika) visits (Cartersville, GA)
```

---

## Family Reference (do NOT ask the user to re-explain these)

### Kids
| Kid | Age/Grade | School | Living Situation |
|-----|-----------|--------|-----------------|
| **David Petry** | ~16–17, homeschooled | At mom Naomi Deal/Revard's in Georgia | Visits DJ in Birmingham on a defined schedule |
| **Charley Ann "CA" Petry** | 12–13, Briarwood Christian | 6th–7th grade | Full-time at 2809 with DJ & Rachel |
| **Tobias "Toby" Bowen** | DOB 10/16/2008, MCAA 10th→11th | Magic City Acceptance Academy (MCAA) | Lives with DJ & Rachel; DJ is legal custodian |
| **Tori "Tide" Bowen** | MCAA 11th→12th | Magic City Acceptance Academy (MCAA) | Lives with DJ & Rachel; DJ is legal custodian |

### Calendar IDs (use these directly — do not call list_calendars)
| Calendar Name | Calendar ID | Notes |
|---|---|---|
| DJ primary | `donpetry@gmail.com` | Main; DJ's work, trips, personal |
| Rachel | `rachel.l.petry@gmail.com` | Rachel's personal |
| Davie in Dad's | `davidjpetry@gmail.com` | David's visits to Birmingham |
| Charley Ann in Dad's | `h9peo9fojaa8b1r3of74b53a0c@group.calendar.google.com` | Charley's activities/events |
| Bowen Kids | `9crfb1328h3s6tsp91rsmditl8@group.calendar.google.com` | Toby & Tide events, CHIPS, work, bio mom visits |
| 2809 Family Calendar | `201577c9b589a11474b31e9171ef79396a210fc09050a66f5280960d1099caa8@group.calendar.google.com` | Whole household events, camps |
| Family Birthdays & Anniversaries | `nbs7jfohhlruae7c4iavmqc45c@group.calendar.google.com` | Birthdays |
| Aunt Kricket (Erika) | `erikabuchkowski@gmail.com` | Check when planning visits with Erika |

---

## Recurring Weekly Schedule (always in effect — verify dates when planning)

These recurring commitments are confirmed from calendar data and must be respected:

| Day | Time | Event | Who | Notes |
|-----|------|-------|-----|-------|
| Monday | 5:30–8pm | CA Dance Class | Charley Ann | Seasonal (Aug–May); Birmingham Academy of Dance |
| Tuesday | 3:30pm | CHIPS appointment | Toby (weekly), Tide (biweekly) | Children's of Alabama; don't schedule competing events |
| Tuesday | 7:40–8:25pm | Taekwondo Kumdo | Charley Ann | School-year pattern |
| Thursday | 5–6pm | "Pirate cracker 🦜" / Date Night | DJ & Rachel | Family tradition every Thursday |
| Thursday | 6pm | Baton lessons (Avie) | Charley Ann | Weekly during school year |
| Thursday | 6:30pm | Roller derby | Tide | At Skates 280; Aunt Kim sometimes attends in person |
| Thursday | 6:30pm | Toby @ Stephens | Toby | Weekly Thursday at friend's house (coincides with Tide's derby) |
| Friday | 7–8pm | Honey BeeHam Business Mtg | DJ, Rachel, Charley Ann | Family beekeeping business meeting |
| Saturday | 11:30am–12:15pm | Taekwondo | Charley Ann | **Year-round every Saturday** — critical constraint |
| Saturday (rotating) | varies | Tide Work | Tide | Cahaba Ridge Retirement Community; also Tue & Thu shifts |
| Sunday | 7:30am | Rescue Food: Publix Tattersall | DJ (& Rachel?) | Volunteer food rescue |
| Sunday | 4pm | DJ & Rachel Gym/Yoga | DJ & Rachel | Weekly |
| Sunday (2x/month) | varies | Bio mom visit | Toby & Tide | Court-ordered (see below) |
| ~24th of month | — | Renew Meds | Toby & Tide | Monthly medication renewal reminder |
| Biweekly Wed | 8–12:30pm | Jacinta (housekeeper) | Household | Clean-up day |

---

## Scheduling Flexibility — Important!

**Most calendar items are flexible with advance notice.** The default posture when planning is: check the calendar first, but assume items can be rescheduled if needed. Specific flexibility notes:

| Item | Flexibility |
|------|-------------|
| Bowen kids bio mom Sunday visits | Flexible — can reschedule with advance notice and CASA coordination |
| Tide's work shifts (Cahaba Ridge) | Flexible — Tide requests days off ideally 2+ weeks in advance |
| Toby's work shifts | Flexible — same 2-week notice preference |
| David's work | Flexible — same |
| Toby & Tide CHIPS counseling | Can skip/reschedule as needed |
| David's counseling | **Virtual only — does NOT block travel at all** |
| Charley Ann's extracurriculars (dance, baton, taekwondo) | Can skip/reschedule for travel |
| School bus / school days | Not a travel blocker; note school is in session |

**True hard stops:** Court dates, non-reschedulable medical procedures, Camp Winshape, Toby/Tide's Thanksgiving trip to Aunt Kim, and any item specifically flagged by the user as fixed.

---

## Court-Ordered Constraints

### David — Appling County Superior Court Order (Georgia, 2012)
David's legal name is David Jonathan Ryo Petry (DOB: 1/30/2010). Naomi Deal/Revard is primary physical custodian. DJ has joint legal custody.

**Minimum court-ordered parenting time for DJ:**
- Every 4th weekend, Thu 4pm → Sun 5pm
- First full week of each month, first Sunday at 5pm → following Sunday at 5pm
- (School age provision): Every 2nd, 3rd, 4th, and 5th weekend from school dismissal Friday → Sunday 5pm

**In practice**: DJ pursues maximum time; actual schedule is negotiated and tracked in the Google Calendar — go by what's in the calendar, not the minimum order.

**Thanksgiving alternation:**
- **Even years**: DJ has David (from last school day → Sunday 5pm following Thanksgiving)
- **Odd years**: Naomi has David
- 2026 = EVEN year → **DJ has David for Thanksgiving 2026**
- This means Toby & Tide's Jacksonville trip goes in an ODD year (2027, 2029, etc.) when David is at Naomi's

**Christmas alternation (per order):**
- **Even years**: DJ gets "before Christmas" — Dec 18 at 3:30pm → Dec 26 at 2pm
- **Odd years**: DJ gets "after Christmas" — Dec 26 at 2pm → Jan 2 at 5pm
- 2026 = EVEN year → **DJ has David Dec 18–26, 2026**

**Summer:** DJ chooses the weeks; **weeks can be consecutive** (no restriction). Must notify Naomi 30 days in advance. Extended summer blocks are common and often negotiated beyond the minimum.

**Transportation:** DJ is responsible for pickup and drop-off; DJ pays all transportation costs.

**Mother's Day:** Naomi always has David for Mother's Day — never schedule a David visit that covers Mother's Day weekend. If a visit block would overlap Mother's Day, end it the Friday before or begin it the Monday after.

### Bowen Kids — Shelby County Juvenile Court Order (Alabama, Sept 2025)
- Bio mom: **Kristen Bowen** (`kk76ripple@gmail.com`)
- Minimum 2 visits/month, Sundays, 3 hours each
- CASA-supervised; public location; within 20 miles of 2809 Five Oaks Lane; Kristen cannot drive the kids
- Also: counseling with mom ~2x/month at Lawley Counseling, Hoover AL
- **These can be rescheduled** with advance notice and CASA coordination

### Tide's Work Schedule
- Part-time job at Cahaba Ridge Retirement Community, 3090 Healthy Way, Vestavia Hills
- Shifts: Saturdays confirmed; rotating Tuesdays and Thursdays
- **Flexible** — Tide requests days off 2+ weeks in advance

### CHIPS Appointments
- Toby: weekly Tuesdays 3:30pm at Children's of Alabama
- Tide: biweekly Tuesdays 3:30pm
- **Flexible** — can skip/reschedule as needed

### CASA Visits
- Biweekly at Hoover Public Library with advocate Kris + Melissa
- **Flexible** — can reschedule with notice

---

## David's Visitation Rules

- **Pickup**: Fridays at 2–3pm EST from Georgia (Naomi Deal/Revard's)
- **Drop-off**: 9 days later, Sunday at 5pm EST back to Georgia
- **Goal**: minimum 1 visit/month during school year; summer blocks can be 2–3 weeks
- **Thanksgiving**: alternates between DJ's household and Naomi's each year
- **Christmas**: "before Christmas" and "after Christmas" blocks alternate each year
- DJ's goal = maximum time; Naomi's goal = minimum — flag any gaps > 5 weeks
- David cannot be left home alone or alone with only other kids
- When David is present, getaway weekends need an additional adult at home

---

## Aunt Kim (Toby & Tide)

- **Who**: Kim Ripple — sister of Logan Bowen (deceased biological father of Toby & Tide)
- **Where she lives**: Jacksonville, FL
- **How kids get there**: Fly Delta roundtrip, BHM (Birmingham) → JAX (Jacksonville)
- **When**: **EVERY Thanksgiving, every year — this is a fixed annual tradition**
- **Duration**: Weekend to weekend — depart Sat or Sun before Thanksgiving, return the following Sat (~7–8 days)
- This is independent of David's schedule — Toby & Tide always go regardless of whether David is at DJ's or Naomi's
- **Note**: Aunt Kim also sometimes comes to Birmingham and attends Tide's Thursday roller derby at Skates 280
- Toby has a hearing disability (wears hearing aids) — note on travel plans
- Tide has a job — confirm shifts covered before booking; 2+ weeks notice preferred

---

## Grandparents — Babbi & GE

- DJ's parents; live in **Panama City, FL** (beach destination — visits often mean a beach trip)
- Can come to Birmingham OR family drives/flies to Panama City
- Ideal windows: household is full (all 4 kids home) OR a kids' event Babbi & GE would enjoy
- Not ideal to overlap with DJ/Rachel getaway or David drop-off/pickup weekends

## Aunt Erika "Kricket" — Erika Buchkowski

- Calendar: `erikabuchkowski@gmail.com` — **always check this calendar when planning a visit with her**
- Lives in **Cartersville, GA** (near Camp Winshape — good combination visit)
- Availability: typically **Friday night → Sunday afternoon**
- Note: Erika has ongoing medical appointments (vision therapy, vestibular therapy, neurologist follow-ups) — her Thursdays and select weekdays are often booked with medical. Weekends are generally clearer but verify.
- When planning a visit with Erika, query her calendar for the proposed weekend and confirm no conflicts

---

## DJ & Rachel Getaway Weekends

Coverage options (mix and match as needed):
- **Charley Ann** → Jackie Basik can host anytime (no advance booking, always available)
- **Toby & Tide** → Can stay home alone for a weekend, OR adult friend Hannah Langford (`hannah.langford96@gmail.com`) stays the night
- **David** → Must be at Naomi's when DJ & Rachel travel; David cannot stay home with only other kids

Ideal getaway weekend conditions:
- [ ] David is at Naomi's (not a David visit block or transition weekend)
- [ ] No bio mom Sunday visit that weekend
- [ ] No Tide work conflicts (or she can get shifts covered)
- [ ] No Charley Ann competitions requiring parent transport
- [ ] Charley Ann covered by Jackie
- [ ] Toby & Tide home or Hannah available

---

## Non-Negotiable Annual Fixed Events

These are immovable — never schedule anything competing with them:

| Event | Who | Timing | Notes |
|-------|-----|--------|-------|
| **Camp Winshape** | Household kids | ~Late May → mid-June (2026: May 31–Jun 14) | Multi-week sleepaway camp; dates vary by year — fetch from 2809 Family Calendar |
| **Toby & Tide — Aunt Kim (Jacksonville)** | Toby & Tide | Thanksgiving: Sat/Sun before → following Sat | Every year, no exceptions; fly Delta BHM→JAX |
| **Honey Pull Week** | DJ & Rachel | 4th of July week (July 4 ± a few days) | Annual honey extraction + neighborhood event; **protect DJ & Rachel's full availability this week** — no getaways, no David drop-off/pickup logistics, no competing commitments |

## Beekeeping Calendar Constraints

DJ runs an active beekeeping operation (Honey BeeHam). Two seasonal patterns affect scheduling:

**Spring — High Demand Season (approx. March–May):**
- Nights and weekends are frequently needed for hive inspections, swarm calls, splits, and honey supers
- When planning DJ & Rachel getaway weekends during spring, flag this as a constraint and confirm DJ's bees are not in a critical phase
- David visits during spring are fine — just avoid stacking a getaway weekend on top of peak beekeeping activity without checking first

**4th of July Week — Honey Pull (immovable):**
- DJ and Rachel extract the season's honey and host a neighborhood event
- **Block DJ & Rachel as unavailable for travel or getaways this entire week**
- David may or may not be visiting during this week — if he is, it's fine (he's at 2809); just don't schedule a DJ/Rachel departure
- Note: Charley Ann helps with the "Honey BeeHam Business Mtg" (Friday evenings year-round) — this is the family beekeeping business

---

## Known School Calendar Landmarks (verify actuals each cycle)

| School | Typical landmarks |
|--------|------------------|
| **Briarwood Christian** (Charley Ann) | 6th grade graduation ~May 20; need to fetch actual break dates at runtime |
| **MCAA** (Toby & Tide) | Graduation Day ~May 26–27; school bus route B via Mountain Brook Community Church; need actual break dates at runtime |
| **David** | Homeschooled; breaks align with what Naomi allows — ask DJ |

---

## Step 1: Determine Planning Period

If `$0` is provided, parse it as the planning period. Otherwise ask:
> "Are we planning the **school year** (Aug–May) or **summer break** (June–Aug)? Which year?"

Set `PERIOD_START` and `PERIOD_END`:
- School year example: `2026-08-01` → `2027-05-31`
- Summer example: `2026-05-20` → `2026-08-10` (adjust to actual last/first school days)

---

## Step 2: Fetch Existing Calendar Data (run all in parallel)

Launch parallel agents or simultaneous tool calls to list events for PERIOD_START → PERIOD_END from:
1. `donpetry@gmail.com` — DJ primary (trips, work travel, holidays)
2. `rachel.l.petry@gmail.com` — Rachel (her personal commitments)
3. `davidjpetry@gmail.com` — Davie in Dad's (existing David visit blocks)
4. `h9peo9fojaa8b1r3of74b53a0c@group.calendar.google.com` — Charley Ann (competitions, camps)
5. `9crfb1328h3s6tsp91rsmditl8@group.calendar.google.com` — Bowen Kids (CHIPS, CASA, Tide work, bio mom visits)
6. `201577c9b589a11474b31e9171ef79396a210fc09050a66f5280960d1099caa8@group.calendar.google.com` — 2809 Family (camps, household events)

From results, build:

**A. Hard Blockers** (days/weeks where specific kids or DJ/Rachel are committed):
- Existing David visit blocks
- Bowen bio mom Sundays
- CHIPS Tuesdays
- Tide work shifts
- Charley Ann competitions (multi-day travel)
- Camps (Winshape, Demo Camp, MOTION, Deaf/STEM, etc.)
- DJ/Rachel work travel

**B. School Breaks** (from calendar or ask user to confirm):
```
Briarwood: Fall break ?, Thanksgiving week ?, Christmas ?, Spring break ?, Summer start ?
MCAA:       Fall break ?, Thanksgiving week ?, Christmas ?, Spring break ?, Summer start ?
```

**C. Holiday Alternation Status** — ask: "Is this a David-at-DJ's or David-at-Naomi's Thanksgiving? And which household has Christmas-before vs. Christmas-after?"

Present clean summary before proceeding:
```
📅 COMMITTED DATES IN [PERIOD]:
  [list by date range]

🚫 BOWEN BIO MOM SUNDAYS (court-ordered, do not conflict):
  [list known Sundays from calendar]

🎓 SCHOOL BREAKS:
  Briarwood: [dates or "TBD — please confirm"]
  MCAA:       [dates or "TBD — please confirm"]

⚠️  TIDE WORK SHIFTS:
  [list from Bowen Kids calendar]
```

---

## Step 3: Gather Planning Inputs

Ask the user (combine into one prompt where possible):

### A. David's Visits
1. How many visits are we targeting for this period?
2. Any specific weeks David must be here? (his birthday, a sibling event, holiday)
3. Any weeks that definitely don't work for a visit?
4. Is this a David-at-DJ's or David-at-Naomi's **Thanksgiving**?
5. For Christmas: which household gets "before" and which gets "after"?

### B. Grandparent Visits (Babbi & GE)
1. Are Babbi & GE coming this cycle? To Birmingham, or are you visiting them?
2. Rough timing preference (e.g., a holiday, a kids' event)?
3. Typical visit length?

### C. Toby & Tide — Aunt Kim Trip
1. Is this the year for the Jacksonville Thanksgiving trip?
2. Preferred travel dates? (typically Wed before Thanksgiving → Sun after)
3. Any concerns about Tide's work schedule for that week?

### D. DJ & Rachel Getaways
1. How many getaway weekends are you hoping for?
2. Any specific destinations or events with fixed dates?
3. Any weekends that must be skipped?

---

## Step 4: Build the Schedule Proposal

### David Visit Algorithm
For each proposed visit:
1. **Start Friday** (pickup ~2pm EST from Georgia)
2. **End Sunday 9 days later** (drop-off 5pm EST)
3. Verify: no DJ/Rachel work travel that week
4. Verify: not a Bowen bio mom Sunday (the drop-off Sunday)
5. Verify: Charley Ann not at an out-of-town competition requiring DJ/Rachel transport
6. For **summer blocks**: can extend to 2–3 weeks; verify MCAA/Briarwood are out so scheduling is simpler
7. For **Thanksgiving/Christmas**: apply alternation rule
8. **Flag** any gap > 5 weeks between visits

### Getaway Weekend Algorithm
Ideal getaway must satisfy ALL:
- [ ] Not a David visit block or transition weekend (Fri pickup / Sun drop-off)
- [ ] No Bowen bio mom Sunday that weekend
- [ ] No Tide work shifts that can't be covered (or she's okay taking off)
- [ ] No Charley Ann out-of-town competition
- [ ] Charley Ann's Saturday Taekwondo accounted for (Jackie can drop her off)
- [ ] Jackie Basik available for Charley Ann overnight (assume yes unless flagged)

### Thanksgiving Planning Logic
```
EVERY YEAR — Toby & Tide go to Jacksonville (Aunt Kim):
  → Book Delta BHM→JAX round trip
  → Depart: Sat or Sun before Thanksgiving week
  → Return: Following Sat (~7–8 days total)
  → Flag: Tide needs work shifts covered for the week
  → Flag: Book Delta flights early — holiday routes fill fast

EVEN years (2026, 2028…) → David ALSO at DJ's for Thanksgiving:
  → David visit overlaps Thanksgiving week
  → DJ & Rachel have David + Charley Ann at home; Toby & Tide in Jacksonville
  → Quieter household — good window for a DJ/Rachel getaway? (No — David is present)

ODD years (2027, 2029…) → David at Naomi's for Thanksgiving:
  → DJ & Rachel have just Charley Ann at home during Thanksgiving week
  → Could be a DJ/Rachel getaway window with Charley Ann at Jackie's
```

### Grandparent Visit Windows
Identify 2–4 candidate windows where:
- Household is NOT fragmented (all 4 kids home, or at least the home kids)
- A specific event Babbi & GE might enjoy is happening (graduation, performance, game)
- Not overlapping DJ/Rachel getaway

---

## Step 5: Present the Schedule Proposal

Output in this format:

```
═══════════════════════════════════════════════════
  PETRY/BOWEN FAMILY SCHEDULE — [PERIOD]
═══════════════════════════════════════════════════

📌 DAVID'S VISITS  ([N] blocks)
  Visit 1:  Fri [date] pickup → Sun [date+9] drop-off
  Visit 2:  Fri [date] pickup → Sun [date+9] drop-off
  ...
  ⚠️  Gap alert: [X weeks] between Visit N and N+1  ← flag if >5 weeks

🦃 THANKSGIVING ([year])
  David's Thanksgiving:   [DJ's / Naomi's]
  Toby & Tide:            [Jacksonville trip / home]
  If JAX trip → Depart [date], Return [date] | Delta BHM→JAX

🎄 CHRISTMAS ([year])
  David "before":  [arrival date] → [departure date]
  David "after":   [arrival date] → [departure date]

🏡 GRANDPARENT VISITS  (Babbi & GE)
  Visit:  [start] → [end]  |  [Location: BHM or travel to them]

🌴 DJ & RACHEL GETAWAYS  ([N] weekends)
  Weekend 1:  Fri [date] → Sun [date]
    Coverage: CA @ Jackie's | Toby/Tide: [home alone / Hannah stays]
  Weekend 2:  Fri [date] → Sun [date]
    Coverage: ...

⚠️  CONFLICTS / FLAGS:
  [list any issues detected]

📋 ASSUMPTIONS MADE:
  [list gaps, e.g., "Assumed Briarwood Thanksgiving break is Nov 23–28 — please confirm"]
```

Then ask: **"Does this plan work? Any adjustments before I create the calendar events?"**

---

## Step 6: Refine if Needed

Apply requested changes, re-check constraints, re-present. Repeat until approved.

---

## Step 7: Create Google Calendar Events

Once approved, create ALL events:

### David Visits → `davidjpetry@gmail.com` + `201577c9b589a11474b31e9171ef79396a210fc09050a66f5280960d1099caa8@group.calendar.google.com`
```
Title:      "Davie @ Petry's"
Start:      [Friday] 14:00 CT
End:        [Sunday + 9 days] 17:00 ET
Attendees:  donpetry@gmail.com, rachel.l.petry@gmail.com
Calendar:   davidjpetry@gmail.com
```

### Aunt Kim Trip → `9crfb1328h3s6tsp91rsmditl8@group.calendar.google.com` (Bowen Kids)
```
Title:       "Toby & Tide — Aunt Kim (Jacksonville)"
Start:       [departure date]
End:         [return date]
Description: "Delta roundtrip BHM→JAX. Staying with Aunt Kim (Kim Ripple, Logan's sister). Tide: confirm work shifts covered."
Calendar:    Bowen Kids
```

### Grandparent Visits → `201577c9b589a11474b31e9171ef79396a210fc09050a66f5280960d1099caa8@group.calendar.google.com`
```
Title:    "Babbi & GE Visit" or "Visit Babbi & GE"
Calendar: 2809 Family Calendar
```

### DJ & Rachel Getaways → `donpetry@gmail.com` + `rachel.l.petry@gmail.com`
```
Title:       "DJ & Rachel Getaway — [Destination]"
Start:       [Friday]
End:         [Sunday]
Description: "CA @ Jackie Basik's. Toby/Tide: [home alone / Hannah Langford staying over]."
Calendar:    donpetry@gmail.com, rachel.l.petry@gmail.com
```

### After creating events, output:
```
✅ Created [N] calendar events:
  • [event title] → [date] → [calendar name]
  ...

📌 Action items for you:
  □ Book Delta flights: BHM→JAX [dates] for Toby & Tide
  □ Confirm with Naomi: David pickup [date] at 2-3pm EST
  □ Confirm with Naomi: David drop-off [date] at 5pm EST
  □ Have Tide check/swap work shifts for [dates] if traveling
  □ Confirm Briarwood break dates for next planning cycle
  □ Confirm MCAA break dates for next planning cycle
  [any other action items discovered during planning]
```

---

## Step 8: Draft Email to Naomi

After calendar events are created, draft a friendly, warm email to Naomi summarizing the proposed David visit schedule for her review and approval. Tone should be cooperative and positive — the goal is easy agreement, not negotiation friction.

```
To:      [Naomi's email — ask DJ if not known]
Subject: David's Visit Schedule — [Period] 🗓️

Hi Naomi,

Hope you're doing well! We've been doing our planning for [school year / summer] 
and wanted to share David's proposed visit schedule with you for your review.

Here are the dates we'd love to have David:

  Visit 1:  [Fri date] → [Sun date]  ([X] days)
  Visit 2:  [Fri date] → [Sun date]  ([X] days)
  ...
  [Thanksgiving block if applicable: Fri Nov XX → Sun Nov XX]
  [Christmas block: Dec 18 → Dec 26 / Dec 26 → Jan 2]

As always, we'll handle all transportation and will have him back to you 
by [drop-off time] on the Sundays listed.

We know schedules shift — if any of these dates don't work for you or 
David, just let us know and we'll find something that does. We're 
flexible on timing as long as we can get our time together.

Looking forward to seeing him! Please reply to confirm or suggest 
any adjustments.

Warm regards,
DJ & Rachel
678-898-0127
```

**Notes for the email:**
- Always mention DJ & Rachel's phone number (678-898-0127) for easy reply
- Omit any visit that is already on the Davie calendar (already confirmed)
- If Mother's Day is anywhere near a proposed visit, proactively note "We've kept Mother's Day weekend clear for you, of course"
- Keep it brief and warm — Naomi responds better to friendly outreach than formal requests
- After drafting, ask DJ: "Want me to send this, save it as a draft in Gmail, or copy it to your clipboard?"

---

## Important Rules

1. **Never** schedule competing events on Bowen kids' court-ordered Sunday bio mom visits
2. **Never** schedule a David visit without a clear Fri pickup → Sun + 9 days drop-off block
3. **Always** flag gaps > 5 weeks between David visits (DJ wants maximum time)
4. **Always** check Tide's work schedule before committing her to out-of-town travel
5. **Always** verify Charley Ann's Saturday Taekwondo when planning her schedule (year-round, 11:30am)
6. **Never** leave Charley Ann or David home alone or with only other kids — adult supervision required
7. When school break dates are uncertain, state the assumption and ask for confirmation before creating events
8. Toby has a hearing disability (wears hearing aids) — note on travel plans and flag for ADA accommodations if relevant
9. The Thanksgiving holiday alternation (David vs. Toby/Tide Jacksonville) is the master coordination point for November — resolve this first before scheduling anything else in that month
