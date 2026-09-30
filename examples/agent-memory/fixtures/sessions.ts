// Synthetic session fixtures for the agent-memory demo.
//
// Small, hand-crafted — the point is to exercise WormDB end-to-end with
// text that produces discriminable hash-embedder vectors, not to be a
// realistic conversation corpus. MemoryMark will grow a proper synthetic
// generator that drives this role in production benchmarks.

export type SessionTurn = {
  role: "user" | "assistant";
  content: string;
};

export type Session = {
  id: string;
  date: string; // ISO date
  tags: string[];
  turns: SessionTurn[];
};

export const SESSIONS: Session[] = [
  {
    id: "s-alice-01",
    date: "2026-01-14",
    tags: ["travel", "planning"],
    turns: [
      { role: "user", content: "I'm thinking about a trip to Kyoto in April." },
      { role: "assistant", content: "April is cherry blossom season in Kyoto — expect crowds at Philosopher's Path and Arashiyama." },
      { role: "user", content: "Should I book ryokan accommodations in advance?" },
      { role: "assistant", content: "Yes, traditional ryokans book out months ahead during sakura. Gion district tends to fill first." },
    ],
  },
  {
    id: "s-alice-02",
    date: "2026-01-21",
    tags: ["travel", "food"],
    turns: [
      { role: "user", content: "What kaiseki restaurants would you recommend in Kyoto?" },
      { role: "assistant", content: "Kikunoi and Hyotei are classics. Kikunoi Honten has a more traditional multi-course experience." },
      { role: "user", content: "Any vegetarian-friendly options?" },
      { role: "assistant", content: "Shojin ryori at temple restaurants like Shigetsu at Tenryu-ji is entirely vegetarian and grounded in Zen tradition." },
    ],
  },
  {
    id: "s-bob-01",
    date: "2026-02-03",
    tags: ["coding", "rust"],
    turns: [
      { role: "user", content: "How do I express sum types in Rust?" },
      { role: "assistant", content: "Use `enum` — Rust enums are full algebraic data types with variants that can carry data." },
      { role: "user", content: "And pattern matching?" },
      { role: "assistant", content: "`match` is exhaustive over variants and also works on tuples, references, and slice patterns." },
    ],
  },
  {
    id: "s-bob-02",
    date: "2026-02-10",
    tags: ["coding", "rust", "async"],
    turns: [
      { role: "user", content: "I'm confused about async cancellation in Tokio." },
      { role: "assistant", content: "Dropping a future cancels it. `tokio::select!` drops the losing branch, which can leave resources in weird states." },
      { role: "user", content: "How do I ensure cleanup runs?" },
      { role: "assistant", content: "Structure cleanup in Drop impls, or use `tokio::spawn` with an explicit cancellation token from `tokio-util`." },
    ],
  },
  {
    id: "s-carol-01",
    date: "2026-03-02",
    tags: ["health", "sleep"],
    turns: [
      { role: "user", content: "I've been waking up at 3am every night for a week." },
      { role: "assistant", content: "Cortisol spikes can cause early-morning wakings, often triggered by stress, alcohol, or evening blood-sugar dips." },
      { role: "user", content: "I did cut caffeine after noon but no improvement." },
      { role: "assistant", content: "Caffeine has a 5-7h half-life so that helps, but try a small protein snack before bed — it stabilizes glucose overnight." },
    ],
  },
  {
    id: "s-carol-02",
    date: "2026-03-09",
    tags: ["health", "exercise"],
    turns: [
      { role: "user", content: "I'm starting to train for a half marathon in October." },
      { role: "assistant", content: "Good window — aim for base-building through June with mostly zone 2 runs, then add tempo and intervals from July." },
      { role: "user", content: "How many days a week should I run?" },
      { role: "assistant", content: "Four is a solid starting point for a first half: two easy, one long, one tempo. Rest days matter for adaptation." },
    ],
  },
  {
    id: "s-dave-01",
    date: "2026-03-18",
    tags: ["music", "piano"],
    turns: [
      { role: "user", content: "I want to learn Rachmaninoff's Prelude in C# minor." },
      { role: "assistant", content: "It's deceptively technical — the chord stretches in the middle section are demanding. Build up to it with easier preludes first." },
      { role: "user", content: "What are reasonable preparatory pieces?" },
      { role: "assistant", content: "Chopin's Prelude in E minor and Rachmaninoff's own Op. 23 No. 4 in D major are good stepping stones for voicing and control." },
    ],
  },
  {
    id: "s-dave-02",
    date: "2026-04-01",
    tags: ["music", "theory"],
    turns: [
      { role: "user", content: "Why do jazz players talk about ii-V-I so much?" },
      { role: "assistant", content: "It's the most common cadential progression in tonal jazz — the ii-V sets up tension that resolves to the I. Nearly every standard has it." },
      { role: "user", content: "Is there an equivalent in modal jazz?" },
      { role: "assistant", content: "Modal jazz often avoids functional cadences entirely — think of So What, which stays on one mode for long stretches and uses fourth-based voicings." },
    ],
  },
];

/// Flatten a session into one "chunk" per turn. The chunking policy is
/// dumb-by-design: one chunk per turn, plus some session-level metadata
/// carried on the chunk. Real systems chunk smarter; the contract is
/// that `mem_add` takes one chunk at a time.
export type Chunk = {
  doc_id: string;
  text: string;
  meta: {
    session_id: string;
    session_date: string;
    session_tags: string[];
    turn_index: number;
    role: "user" | "assistant";
  };
};

export function flatten(sessions: Session[]): Chunk[] {
  const out: Chunk[] = [];
  for (const s of sessions) {
    for (let i = 0; i < s.turns.length; i += 1) {
      const t = s.turns[i];
      out.push({
        doc_id: `${s.id}-t${i}`,
        text: t.content,
        meta: {
          session_id: s.id,
          session_date: s.date,
          session_tags: s.tags,
          turn_index: i,
          role: t.role,
        },
      });
    }
  }
  return out;
}
