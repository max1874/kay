//! Your own spellings, put in place after recognition with no model involved: the Mac's `Vocabulary.swift`. One
//! term per line in `vocabulary.txt`, `#` at the start or after a space starts a comment, and how it gets misheard
//! may follow after `|`: `Raycast | 瑞卡斯特`.
//!
//! Only spans that are certainly the term are replaced:
//! - the term spelled out letter by letter ("c f" → CF, "k a y" → Kay); not words that join into it, since
//!   "type switch" and "ray cast" are English before they are TypeSwitch and Raycast;
//! - the term with its digits read out, next to Chinese ("切到 e to b" → E2B; "from E to B" is English);
//! - an alias, written exactly as you wrote it.
//! A change of case alone ("cursor") is not one. Terms with punctuation (C++, .NET) are kept but never matched.
//! Replacing twice changes nothing more, since Kay runs it before DeepSeek and again on its answer. Nothing here
//! reaches the speech service or DeepSeek: as hot words or as hints, a list pulled unrelated speech towards its
//! terms (asr-lexicon eval/kay/VOCABULARY.md).

use std::{
    fs,
    ops::Range,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::SystemTime,
};

#[derive(Clone, PartialEq)]
struct Term {
    text: String,
    aliases: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Term,
    Reading,
    Alias,
}

/// One way a term can be heard.
struct Form {
    term: String,
    units: Vec<Unit>,
    kind: Kind,
}

/// What is compared: a Latin letter or digit, lower-cased, or any other letter as it is. A match starts at a
/// word's first unit and ends at a word's last: inside "pcfx" there is no CF. Every Chinese character is a word.
#[derive(Clone)]
struct Unit {
    value: char,
    latin: bool,
    starts: bool,
    ends: bool,
    range: Range<usize>,
}

#[derive(Clone)]
pub struct Match {
    range: Range<usize>,
    term: String,
}

#[derive(Default)]
pub struct Vocabulary {
    terms: Vec<Term>,
    forms: Vec<Form>,
}

const DIGIT_WORDS: [&[(char, &str)]; 3] = [
    &[('0', "zero"), ('1', "one"), ('2', "two"), ('3', "three"), ('4', "four"), ('5', "five"), ('6', "six"), ('7', "seven"), ('8', "eight"), ('9', "nine")],
    // How a recognizer writes a digit it heard as a word.
    &[('2', "to"), ('4', "for")],
    &[('0', "零"), ('1', "一"), ('2', "二"), ('3', "三"), ('4', "四"), ('5', "五"), ('6', "六"), ('7', "七"), ('8', "八"), ('9', "九")],
];

impl Vocabulary {
    pub fn parse(text: &str) -> Vocabulary {
        let mut terms: Vec<Term> = Vec::new();
        for raw in text.lines() {
            // C# keeps its #: a comment starts a line or follows a space.
            let comment = raw.char_indices().find(|&(i, c)| c == '#' && raw[..i].chars().last().is_none_or(char::is_whitespace));
            let line = &raw[..comment.map_or(raw.len(), |(i, _)| i)];
            let mut fields = line.split('|').map(str::trim).filter(|f| !f.is_empty()).map(String::from);
            let Some(text) = fields.next() else { continue };
            let aliases: Vec<String> = fields.collect();
            // A term on two lines keeps the aliases of both.
            match terms.iter_mut().find(|t| t.text == text) {
                Some(term) => term.aliases.extend(aliases),
                None => terms.push(Term { text, aliases }),
            }
        }
        let forms = forms(&terms);
        Vocabulary { terms, forms }
    }

    pub fn len(&self) -> usize {
        self.terms.len()
    }

    /// The spans to replace, left to right, none overlapping; the longer span wins where two would.
    pub fn replacements(&self, text: &str) -> Vec<Match> {
        let mut found = Vec::new();
        // Where the term itself is said, in any case or spacing.
        let mut said = Vec::new();
        for segment in segments(text) {
            for form in &self.forms {
                for (found_match, replaces) in find(form, &segment, text) {
                    if replaces {
                        found.push(found_match.clone());
                    }
                    if form.kind == Kind::Term {
                        said.push(found_match);
                    }
                }
            }
        }
        // Inside the term already: an alias that is part of its term (Claude for Claude Code) would otherwise grow it
        // on every pass.
        found.retain(|m: &Match| {
            !said.iter().any(|s: &Match| {
                s.term == m.term && s.range != m.range && s.range.start <= m.range.start && m.range.end <= s.range.end
            })
        });
        let length = |m: &Match| text[m.range.clone()].chars().count();
        found.sort_by_key(|m| std::cmp::Reverse(length(m)));
        let mut kept: Vec<Match> = Vec::new();
        for m in found {
            if !kept.iter().any(|k| k.range.start < m.range.end && m.range.start < k.range.end) {
                kept.push(m);
            }
        }
        kept.sort_by_key(|m| m.range.start);
        kept
    }

    /// `matches` from `replacements(text)`.
    pub fn apply(&self, matches: &[Match], text: &str) -> String {
        let mut result = text.to_string();
        for m in matches.iter().rev() {
            result.replace_range(m.range.clone(), &m.term);
        }
        result
    }

    pub fn apply_all(&self, text: &str) -> String {
        self.apply(&self.replacements(text), text)
    }

    pub fn path() -> PathBuf {
        crate::files::data().join("vocabulary.txt")
    }

    /// The list as the file has it now. Read again only when the file changed, so a dictation costs a stat.
    pub fn current() -> Arc<Vocabulary> {
        static CACHE: Mutex<Option<(Option<SystemTime>, Arc<Vocabulary>)>> = Mutex::new(None);
        let modified = fs::metadata(Self::path()).and_then(|m| m.modified()).ok();
        let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((date, vocabulary)) = cache.as_ref() {
            if *date == modified {
                return vocabulary.clone();
            }
        }
        let vocabulary = Arc::new(Vocabulary::parse(&Self::text()));
        *cache = Some((modified, vocabulary.clone()));
        vocabulary
    }

    pub fn text() -> String {
        fs::read_to_string(Self::path()).unwrap_or_default()
    }

    /// Writes through a symlink rather than replacing it.
    pub fn save(text: &str) -> bool {
        let _ = fs::create_dir_all(crate::files::data());
        fs::write(Self::path(), text).is_ok()
    }
}

fn forms(terms: &[Term]) -> Vec<Form> {
    let mut forms = Vec::new();
    for term in terms {
        let mut heard = vec![(term.text.clone(), Kind::Term)];
        for words in DIGIT_WORDS {
            let word = |c: char| words.iter().find(|(d, _)| *d == c).map(|(_, w)| *w);
            if term.text.chars().any(|c| word(c).is_some()) {
                let reading = term.text.chars().map(|c| word(c).map_or(c.to_string(), |w| format!(" {w} "))).collect();
                heard.push((reading, Kind::Reading));
            }
        }
        heard.extend(term.aliases.iter().map(|a| (a.clone(), Kind::Alias)));
        for (text, kind) in heard {
            if !text.chars().all(|c| c.is_alphabetic() || c.is_numeric() || c.is_whitespace()) {
                continue;
            }
            let units: Vec<Unit> = segments(&text).into_iter().flatten().collect();
            if !units.is_empty() {
                forms.push(Form { term: term.text.clone(), units, kind });
            }
        }
    }
    forms
}

/// The units of each run of text between punctuation: a match never crosses a comma.
fn segments(text: &str) -> Vec<Vec<Unit>> {
    let mut segments = Vec::new();
    let mut current: Vec<Unit> = Vec::new();
    let mut latin: Vec<(char, Range<usize>)> = Vec::new();

    // A word also splits where letters meet digits and where lower case meets upper (OpenAI → Open AI), so E2B
    // is three words and lines up with "e to b".
    let flush_latin = |latin: &mut Vec<(char, Range<usize>)>, current: &mut Vec<Unit>| {
        let mut word: Vec<Unit> = Vec::new();
        let flush_word = |word: &mut Vec<Unit>, current: &mut Vec<Unit>| {
            if let Some(first) = word.first_mut() {
                first.starts = true;
            }
            if let Some(last) = word.last_mut() {
                last.ends = true;
            }
            current.append(word);
        };
        let mut previous: Option<char> = None;
        for (c, range) in latin.drain(..) {
            if let Some(p) = previous {
                if p.is_ascii_digit() != c.is_ascii_digit() || (p.is_ascii_lowercase() && c.is_ascii_uppercase()) {
                    flush_word(&mut word, current);
                }
            }
            word.push(Unit { value: c.to_ascii_lowercase(), latin: true, starts: false, ends: false, range });
            previous = Some(c);
        }
        flush_word(&mut word, current);
    };

    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        let range = i..i + c.len_utf8();
        let next = chars.peek().map(|&(_, n)| n);
        if c.is_ascii_alphanumeric() {
            latin.push((c, range));
        } else if (c == '\'' || c == '’') && !latin.is_empty() && next.is_some_and(|n| n.is_ascii_alphabetic()) {
            // Inside a word ("I'm"): neither a unit nor a break.
        } else if c.is_whitespace() && c != '\n' && c != '\r' {
            flush_latin(&mut latin, &mut current);
        } else if c.is_alphabetic() {
            flush_latin(&mut latin, &mut current);
            current.push(Unit { value: c, latin: false, starts: true, ends: true, range });
        } else {
            flush_latin(&mut latin, &mut current);
            if !current.is_empty() {
                segments.push(std::mem::take(&mut current));
            }
        }
    }
    flush_latin(&mut latin, &mut current);
    if !current.is_empty() {
        segments.push(current);
    }
    segments
}

/// Every place `form` occurs in `segment` unit for unit, starting and ending on word boundaries, and whether it is
/// certainly the term.
fn find(form: &Form, segment: &[Unit], text: &str) -> Vec<(Match, bool)> {
    let p = &form.units;
    if p.len() > segment.len() {
        return vec![];
    }
    let mut found = Vec::new();
    for start in 0..=segment.len() - p.len() {
        let end = start + p.len();
        let span = &segment[start..end];
        if !span[0].starts || !span[span.len() - 1].ends || !p.iter().zip(span).all(|(a, b)| a.value == b.value) {
            continue;
        }
        let range = span[0].range.start..span[span.len() - 1].range.end;
        let heard = &text[range.clone()];
        let words = span.iter().filter(|u| u.starts).count();
        let letters = span.iter().filter(|u| u.starts && u.ends && u.value.is_alphabetic()).count();
        let next_to_chinese = (start > 0 && !segment[start - 1].latin) || (end < segment.len() && !segment[end].latin);
        let replaces = match form.kind {
            Kind::Term => {
                span.iter().all(|u| u.latin && u.starts && u.ends)
                    && words >= 2
                    && heard.to_lowercase() != form.term.to_lowercase()
            }
            Kind::Reading => letters >= 2 && next_to_chinese,
            Kind::Alias => heard != form.term,
        };
        found.push((Match { range, term: form.term.clone() }, replaces));
    }
    found
}
