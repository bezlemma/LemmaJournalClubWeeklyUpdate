import json
import os
import re
import google.generativeai as genai
import time
import datetime
import concurrent.futures

# --- Configuration ---
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
INPUT_FILE = "papers.json"
OUTPUT_FILE = "papers_final.md"
GREEN_AUTHORS_FILE = "greenauthors.txt"

if not GEMINI_API_KEY:
    print("Error: GEMINI_API_KEY environment variable not set.")
    exit(1)

genai.configure(api_key=GEMINI_API_KEY)
model = genai.GenerativeModel('gemini-3-flash-preview')

def normalize_author_identifier(name_str):
    """
    Returns a tuple (last_name_lower, first_initial_lower) for reliable matching.
    Handles: "First Last", "Last, First", "Last, F.", "F. Last".
    """
    name_str = name_str.strip()
    if not name_str:
        return None
    
    # Remove periods
    clean_name = name_str.replace('.', ' ')
    parts = clean_name.replace(',', ' ').split()
    
    if not parts:
        return None
        
    # Heuristic: If there's a comma in the original, usually "Last, First"
    if ',' in name_str:
        # Assumes "Last, First"
        last = name_str.split(',')[0].strip().split()[-1] # Take last word of before-comma part just in case
        # For "Last, First", the part after comma is first name
        after_comma = name_str.split(',')[1].strip()
        if after_comma:
            first_initial = after_comma[0]
        else:
            first_initial = "" # Should not happen often
    else:
        # Assumes "First Last" or "F Last"
        last = parts[-1]
        first_initial = parts[0][0]
        
    return (last.lower(), first_initial.lower())

def load_green_authors_identifiers(filename):
    """
    Returns a SET of (last_name, first_initial) tuples.
    """
    identifiers = set()
    try:
        with open(filename, 'r') as f:
            for line in f:
                line = line.strip()
                if line:
                    ident = normalize_author_identifier(line)
                    if ident:
                        identifiers.add(ident)
    except FileNotFoundError:
        print(f"Warning: {filename} not found.")
    return identifiers

GREEN_AUTHORS_IDENTIFIERS = load_green_authors_identifiers(GREEN_AUTHORS_FILE)

def matches_green_author(paper):
    authors_str = paper.get('authors', '')
    if not authors_str:
        return False
    
    # Strategy 1: Check the entire string as a single author (handles "Last, First" case for single author)
    full_ident = normalize_author_identifier(authors_str)
    if full_ident and full_ident in GREEN_AUTHORS_IDENTIFIERS:
        # print(f"  [MATCH] Found Green Author (Full String): {authors_str} -> {full_ident}")
        return True

    # Strategy 2: Split and check
    # If semicolon is present, it's the strongest delimiter (bioRxiv style: "Last, F.; Last, F.")
    if ';' in authors_str:
        raw_list = authors_str.split(';')
    else:
        # Otherwise split by comma or " and " (Standard: "First Last, First Last")
        # Note: This will break "Last, First, Last, First" list, but that format is rare/ambiguous without semicolons.
        raw_list = re.split(r',|\s+and\s+', authors_str)
    
    for raw_auth in raw_list:
        paper_ident = normalize_author_identifier(raw_auth)
        if paper_ident and paper_ident in GREEN_AUTHORS_IDENTIFIERS:
            # print(f"  [MATCH] Found Green Author: {raw_auth} -> {paper_ident}")
            return True
            
    return False

def classify_paper(paper):
    title = paper['title']
    abstract = paper['abstract']
    
    prompt = f"""
Classify if the provided paper is "Biophysics".

Title: {title}
Abstract: {abstract}

INCLUSION CRITERIA:
- Investigates physical mechanisms (forces, dynamics, thermodynamics, entropy).
- Covers soft/active matter, condensates, or polymer physics in biology.
- Uses quantitative modeling/simulations of biological phenomena.
- Novel physical imaging/instrumentation (Lattice light sheet, etc).
- Novel use of physics to understand biological systems.

EXCLUSION CRITERIA:
- Static structural biology (routine crystallography).
- Purely clinical, medical, or descriptive genetics/omics.
- Pure materials science with no biological application.
- Papers with "Simulation" in the name
- SOFTWARE: Papers focused on introducing or improving a software package, python framework, etc.
- NETWORK ECOLOGY: Food webs, trophic levels, ecosystem robustness, predator-prey population graphs.
- POPULATION DYNAMICS: Lotka-Volterra models, species abundance distributions, biodiversity statistics.
- HIGH-THROUGHPUT SCREENING: "Virtual screening," "Molecular docking studies," or "In silico characterization" of large lists of proteins without deep mechanistic insight.
- ROUTINE MD: Standard molecular dynamics simulations (10-100ns) that just "confirm stability" of a structure without calculating free energies or phase transitions.
- DATABASES: Papers that just present a list of predicted structures (e.g., "Genome-wide analysis of...").

If unsure, default to TRUE.
Reply with a single word: TRUE or FALSE.
"""
    try:
        response = model.generate_content(prompt)
        result = response.text.strip().upper()
        # print(f"  AI Classification for '{title[:30]}...': {result}") # Debug
        if "TRUE" in result:
             return True, "AI Approved"
        else:
             return False, "AI Rejected"
    except Exception as e:
        print(f"  Error classifying '{title[:30]}...': {e}")
        return True, f"Error Fallback: {e}" # Default to keep if AI fails

def summarize_paper(paper):
    title = paper['title']
    abstract = paper['abstract']
    
    prompt = f"""
Provide a one sentence summary of the following paper.
Do not start with a preamble "This study suggests", "The paper describes", "Researchers find", or similar phrases. 
Start directly with the subject of the summary.

Title: {title}
Abstract: {abstract}
"""
    try:
        response = model.generate_content(prompt)
        return response.text.strip()
    except Exception as e:
        print(f"  Error summarizing '{title[:30]}...': {e}")
        return "Summary unavailable."

def process_one_paper(paper):
    """
    Process a single paper: Check Green Authors, then AI Classify.
    Returns: (paper, category) where category is 'featured', 'regular', or None.
    """
    try:
        # 1. Check Green Authors
        if matches_green_author(paper):
            # print(f"  [Green] {paper['title'][:30]}...")
            # SKIP AI SUMMARY for Featured papers, use full abstract
            # We prefix it with specific marker or just store it
            paper['ai_summary'] = "**Full Abstract:** " + paper['abstract']
            return paper, 'featured'
            
        # 2. AI Classification
        is_biophysics, reason = classify_paper(paper)
        
        if is_biophysics:
            # print(f"  [Kept] {paper['title'][:30]}...")
            summary = summarize_paper(paper)
            paper['ai_summary'] = summary
            return paper, 'regular'
        else:
            return paper, None
            
    except Exception as e:
        print(f"Error processing {paper['title'][:30]}...: {e}")
        # Default to regular if catastrophic failure, or just skip? 
        # Current logic is safer to skip if we can't even process it, 
        # but classify_paper handles its own errors.
        return paper, None

def main():
    print("Loading papers from papers.json...")
    try:
        with open(INPUT_FILE, 'r') as f:
            papers = json.load(f)
    except FileNotFoundError:
        print(f"Error: {INPUT_FILE} not found. Run fetch_papers.py first.")
        return

    featured_papers = []
    regular_papers = []
    
    print(f"Processing {len(papers)} papers with parallel execution (10 workers)...")
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        # Submit all tasks
        future_to_paper = {executor.submit(process_one_paper, p): p for p in papers}
        
        # Process as they complete
        completed_count = 0
        for future in concurrent.futures.as_completed(future_to_paper):
            paper, category = future.result()
            completed_count += 1
            
            if category == 'featured':
                featured_papers.append(paper)
                print(f"[{completed_count}/{len(papers)}] ✅ FEATURED: {paper['title'][:40]}...")
            elif category == 'regular':
                regular_papers.append(paper)
                print(f"[{completed_count}/{len(papers)}] 🟢 KEPT: {paper['title'][:40]}...")
            else:
                print(f"[{completed_count}/{len(papers)}] ❌ SKIPPED: {paper['title'][:40]}...")
                pass
                
            if completed_count % 10 == 0:
                print(f"   ... {completed_count}/{len(papers)} done.") 

    # Generate Output
    all_final_papers = featured_papers + regular_papers
    total_kept = len(all_final_papers)
    
    from collections import Counter
    source_counts = Counter([p['source'] for p in all_final_papers])
    breakdown = ", ".join([f"{src}: {count}" for src, count in source_counts.most_common()])
    
    print(f"\nGeneratng {OUTPUT_FILE} with {total_kept} papers...")
    
    with open(OUTPUT_FILE, 'w') as f:
        f.write("# Weekly Paper Update (AI Filtered)\n")
        f.write(f"**Date:** {datetime.datetime.now().strftime('%Y-%m-%d')}\n")
        f.write(f"**Total Papers:** {total_kept} (Selected from {len(papers)} raw)\n")
        f.write(f"**Sources:** {breakdown}\n\n")
        
        if featured_papers:
            f.write("## 🌟 Featured Papers (Green Authors)\n\n")
            for p in featured_papers:
                f.write(f"### {p['title']}\n")
                f.write(f"**Date:** {p.get('date', '')[:10]}\n")
                f.write(f"**Authors:** {p['authors']}\n")
                f.write(f"**Link:** {p['link']}\n\n") 
                # For featured papers, we might have stored "Full Abstract" in ai_summary or just print abstract directly
                # The user requested "whole abstract".
                f.write(f"<details open><summary><strong>Abstract</strong></summary>{p['abstract']}</details>\n")
                f.write("---\n\n")
        
        if regular_papers:
            f.write("## 📚 Biophysics Papers\n\n")
            for p in regular_papers:
                f.write(f"### {p['title']}\n")
                f.write(f"**Date:** {p.get('date', '')[:10]}\n")
                f.write(f"**Authors:** {p['authors']}\n")
                f.write(f"**Link:** {p['link']}\n")
                f.write(f"**AI Summary:** {p['ai_summary']}\n")
                f.write("---\n\n")

    print("Done!")

if __name__ == "__main__":
    main()
