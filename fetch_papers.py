import arxiv
import datetime
from datetime import timedelta
import pytz
import requests
import time
import feedparser
from dateutil import parser as date_parser

# --- Configuration ---
DAYS_BACK = 7
OLDEST_DATE_TO_INCLUDE = datetime.datetime.now(pytz.utc) - timedelta(days=DAYS_BACK)

ARXIV_CATEGORIES = ['physics.bio-ph', 'cond-mat.soft']
BIORXIV_COLLECTION = 'biophysics'

# Load whitelists
def load_list(filename):
    try:
        with open(filename, 'r') as f:
            return [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        print(f"Warning: {filename} not found.")
        return []

GREEN_AUTHORS = load_list('greenauthors.txt')
GREEN_KEYWORDS = load_list('greenkeywords.txt')

def is_research_article(entry):
    # Heuristic to filter out non-research content
    title = entry.get('title', '').lower()
    summary = entry.get('summary', '').lower()
    
    # Exclude common non-research terms in title
    exclude_terms = ['review', 'perspective', 'editorial', 'correction', 'comment', 'highlight', 'news', 'erratum', 'author correction', 'publisher correction']
    if any(term in title for term in exclude_terms):
        return False
        
    # Check Dublin Core type if available
    # feedparser often maps dc:type to entry.get('dc_type') or tags
    # This is feed-dependent, so we might need to inspect tags
    
    return True

def matches_green_filter(entry):
    # Check Authors
    if 'authors' in entry:
        # entry.authors is usually a list of dicts [{'name': '...'}]
        authors_str = " ".join([a.get('name', '') for a in entry.authors]).lower()
    else:
        authors_str = entry.get('author', '').lower()
        
    for green_author in GREEN_AUTHORS:
        if green_author.lower() in authors_str:
            return True
            
    # Check Keywords in Title/Abstract
    text_to_search = (entry.get('title', '') + " " + entry.get('summary', '')).lower()
    for keyword in GREEN_KEYWORDS:
        if keyword.lower() in text_to_search:
            return True
            
    return False

def fetch_rss(url, source_name, group_type, section_filter=None):
    print(f"Fetching {source_name} ({group_type})...")
    papers = []
    
    # Headers to mimic a browser
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://www.google.com/'
    }

    try:
        response = requests.get(url, headers=headers, timeout=15)
        # Check for 403/404
        if response.status_code != 200:
            print(f"  Error: {source_name} returned status {response.status_code}")
            return []

        feed = feedparser.parse(response.content)
        
        if not feed.entries and feed.bozo:
             print(f"  Warning: Issue parsing {source_name} feed: {feed.bozo_exception}")

        for entry in feed.entries:
            # Date Parsing
            published = None
            if 'published_parsed' in entry and entry.published_parsed:
                published = datetime.datetime.fromtimestamp(time.mktime(entry.published_parsed)).replace(tzinfo=pytz.utc)
            elif 'updated_parsed' in entry and entry.updated_parsed:
                 published = datetime.datetime.fromtimestamp(time.mktime(entry.updated_parsed)).replace(tzinfo=pytz.utc)
            
            if not published:
                continue
                
            if published < OLDEST_DATE_TO_INCLUDE:
                continue

            # "Research Article" Constraint
            if not is_research_article(entry):
                continue

            # Group B: Section Filter
            if group_type == 'B' and section_filter:
                tags = [t.get('term', '').lower() for t in entry.get('tags', [])]
                tags += [t.get('label', '').lower() for t in entry.get('tags', [])]
                cat = entry.get('category', '').lower()
                
                # Check tags/category
                category_match = section_filter.lower() in [t.lower() for t in tags] or section_filter.lower() in cat
                
                # Check title/summary for section (e.g. "Biophysics: Title")
                # PNAS titles often don't have it, but maybe summary?
                text_match = section_filter.lower() in entry.get('title', '').lower() or section_filter.lower() in entry.get('summary', '').lower()
                
                if not (category_match or text_match):
                     # If generic feed and strict filter requested, skip.
                     continue

            # Group C: Author/Keyword Filter
            if group_type == 'C':
                if not matches_green_filter(entry):
                    continue

            # Formatting
            authors = []
            if 'authors' in entry:
                authors = [a.get('name', '') for a in entry.authors]
            elif 'author' in entry:
                authors = [entry.author]
            
            paper = {
                'source': source_name,
                'title': entry.title.replace('\n', ' '),
                'authors': ", ".join(authors),
                'link': entry.link,
                'abstract': entry.get('summary', '').replace('\n', ' '),
                'date': published
            }
            papers.append(paper)
            
    except Exception as e:
        print(f"  Error fetching {source_name}: {e}")
        
    print(f"  Found {len(papers)} papers.")
    return papers

def fetch_arxiv_papers():
    print(f"Fetching arXiv papers...")
    # Construct the query
    query_string = " OR ".join([f"cat:{cat}" for cat in ARXIV_CATEGORIES])

    client = arxiv.Client()
    search = arxiv.Search(
        query=query_string,
        max_results=200, 
        sort_by=arxiv.SortCriterion.SubmittedDate,
        sort_order=arxiv.SortOrder.Descending
    )

    papers = []
    seen_ids = set()

    for result in client.results(search):
        published_date = result.published.replace(tzinfo=pytz.utc)
        
        if published_date < OLDEST_DATE_TO_INCLUDE:
            break

        paper_id = result.entry_id.split('/')[-1].split('v')[0]
        
        if paper_id in seen_ids:
            continue
        seen_ids.add(paper_id)

        # "Research Article" check for arXiv? 
        # Usually checking excluding "Review" in title is good enough
        if not is_research_article({'title': result.title, 'summary': result.summary}):
             continue

        papers.append({
            'source': 'arXiv',
            'title': result.title.replace('\n', ' '),
            'authors': ", ".join([author.name for author in result.authors]),
            'link': result.entry_id,
            'abstract': result.summary.replace('\n', ' '),
            'date': published_date
        })
    print(f"  Found {len(papers)} arXiv papers.")
    return papers

def fetch_biorxiv_papers():
    print(f"Fetching bioRxiv papers...")
    start_date_str = OLDEST_DATE_TO_INCLUDE.strftime("%Y-%m-%d")
    end_date_str = datetime.datetime.now(pytz.utc).strftime("%Y-%m-%d")
    
    papers = []
    cursor = 0
    
    while True:
        url = f"https://api.biorxiv.org/details/biorxiv/{start_date_str}/{end_date_str}/{cursor}/json"
        
        # Retry logic for bioRxiv
        max_retries = 3
        data = None
        for attempt in range(max_retries):
            try:
                # print(f"  Debug: Fetching cursor {cursor}...")
                response = requests.get(url, timeout=30)
                response.raise_for_status()
                data = response.json()
                break 
            except Exception as e:
                print(f"  Error fetching bioRxiv: {e}. Retrying ({attempt+1}/{max_retries})...")
                time.sleep(2)
        
        if not data or 'collection' not in data:
            break
        
        for item in data['collection']:
            if item.get('category') and item['category'].lower() == BIORXIV_COLLECTION.lower():
                try:
                    paper_date = datetime.datetime.strptime(item['date'], "%Y-%m-%d").replace(tzinfo=pytz.utc)
                except ValueError:
                    paper_date = datetime.datetime.now(pytz.utc)

                authors = item.get('authors', '')
                papers.append({
                    'source': 'bioRxiv',
                    'title': item['title'].replace('\n', ' '),
                    'authors': authors,
                    'link': f"https://www.biorxiv.org/content/{item['doi']}v{item['version']}",
                    'abstract': item['abstract'].replace('\n', ' '),
                    'date': paper_date,
                    'doi': item['doi']
                })

        messages = data.get('messages', [{}])
        count = int(messages[0].get('count', 0))
        total = int(messages[0].get('total', 0))
        new_cursor = int(messages[0].get('cursor', 0)) + count
        
        if new_cursor >= total or count == 0:
            break
        cursor = new_cursor
        time.sleep(0.5) 

    # Deduplicate bioRxiv
    unique_papers = {}
    for p in papers:
        doi = p.get('doi')
        if doi not in unique_papers:
            unique_papers[doi] = p
        else:
            if p['date'] < unique_papers[doi]['date']:
                unique_papers[doi] = p
    
    final = list(unique_papers.values())
    print(f"  Found {len(final)} bioRxiv papers (biophysics).")
    return final

def fetch_and_display_papers():
    print(f"Fetching papers (Last {DAYS_BACK} days, >= {OLDEST_DATE_TO_INCLUDE.strftime('%Y-%m-%d')})...\n")
    
    all_papers = []
    
    # 1. arXiv
    all_papers.extend(fetch_arxiv_papers())
    
    # 2. bioRxiv
    all_papers.extend(fetch_biorxiv_papers())
    
    # 3. Group A: Specialized (Fetch All)
    # Soft Matter
    all_papers.extend(fetch_rss("http://feeds.rsc.org/rss/sm", "Soft Matter", "A"))
    
    # Biophysical Journal
    all_papers.extend(fetch_rss("https://www.cell.com/biophysj/inpress.rss", "Biophysical Journal", "A"))
    
    # Physical Review E
    all_papers.extend(fetch_rss("https://feeds.aps.org/rss/tocsec/PRE-Biologicalphysics.xml", "Physical Review E", "A"))

    # PRL
    all_papers.extend(fetch_rss("https://feeds.aps.org/rss/tocsec/PRL-SoftMatterBiologicalandInterdisciplinaryPhysics.xml", "PRL", "A"))

    # PRX
    all_papers.extend(fetch_rss("https://feeds.aps.org/rss/recent/prx.xml", "PRX", "A"))

    # PRX Life
    all_papers.extend(fetch_rss("http://feeds.aps.org/rss/recent/prxlife.xml", "PRX Life", "A")) 

    # Nature (Biophysics subject feed)
    all_papers.extend(fetch_rss("http://www.nature.com/subjects/biophysics.rss", "Nature", "A"))

    # PNAS (Biophysics Topic)
    all_papers.extend(fetch_rss("https://www.pnas.org/action/showFeed?type=searchTopic&taxonomyCode=topic&tagCodeOr=biophys-bio&tagCodeOr=biophys-phys", "PNAS", "A"))
   
    # 4. Group B: Broad 
     
    # PNAS Nexus
    all_papers.extend(fetch_rss("https://academic.oup.com/rss/site_6448/4114.xml", "PNAS NEXUS", "B"))
 
    # PLOS ONE
    all_papers.extend(fetch_rss("https://journals.plos.org/plosone/feed/atom?filterJournals=PLoSONE&q=subject%3A%22Biophysics%22", "PLOS ONE", "B"))
    
    # Science
    all_papers.extend(fetch_rss("https://www.science.org/rss/express.xml", "Science", "B", section_filter="Biophysics"))

    # 5. Group C: General (Author/Keyword)
    # Cell
    all_papers.extend(fetch_rss("https://www.cell.com/cell/current.rss", "Cell", "C"))
    # eLife
    all_papers.extend(fetch_rss("https://elifesciences.org/rss/recent.xml", "eLife", "C"))
    # MBoC
    all_papers.extend(fetch_rss("https://www.molbiolcell.org/action/showFeed?type=etoc&feed=rss&jc=mboc", "MBoC", "C"))
    
    # Development [404]
    # all_papers.extend(fetch_rss("https://journals.biologists.com/dev/rss/recent.xml", "Development", "C"))


    # Deduplication
    unique_papers_map = {}
    for p in all_papers:
        # Title normalization: Lowercase, strip punctuation? 
        title_clean = "".join(e for e in p['title'].lower() if e.isalnum())
        
        # Or checking Link equality
        link = p['link']
        
        # Primary key: Title seems appropriate for cross-feed dedup (e.g. arXiv vs Journal)
        # But titles can change slightly.
        # Let's try Title + First Author Surname?
        # For now, strict Title equality.
        if title_clean not in unique_papers_map:
            unique_papers_map[title_clean] = p
        else:
            # Keep earliest date?
            if p['date'] < unique_papers_map[title_clean]['date']:
                unique_papers_map[title_clean] = p
            
    final_list = list(unique_papers_map.values())
    
    # Sort by date descending
    final_list.sort(key=lambda x: x['date'], reverse=True)
    
    total_count = len(final_list)
    
    output_lines = []
    
    for paper in final_list:
        output_lines.append(f"### {paper['title']}")
        output_lines.append(f"**Source:** {paper['source']}")
        output_lines.append(f"**Date:** {paper['date'].strftime('%Y-%m-%d')}")
        output_lines.append(f"**Authors:** {paper['authors']}")
        output_lines.append(f"**Link:** {paper['link']}")
        output_lines.append(f"<details>")
        output_lines.append(f"<summary><strong>Abstract</strong></summary>")
        output_lines.append(f"{paper['abstract']}")
        output_lines.append(f"</details>")
        output_lines.append("") 
        output_lines.append("---")
        output_lines.append("")

    # Write to file
    with open("papers.md", "w") as f:
        f.write(f"# Weekly Paper Update\n")
        f.write(f"**Date Range:** {OLDEST_DATE_TO_INCLUDE.strftime('%Y-%m-%d')} to {datetime.datetime.now().strftime('%Y-%m-%d')}\n")
        f.write(f"**Total Papers Found:** {total_count}\n\n")
        
        if not output_lines:
            f.write("No papers found in this date range.\n")
        else:
            f.write("\n".join(output_lines))
    
    print(f"\nDone. Found {total_count} total unique papers.")
    print("Saved to papers.md")

if __name__ == "__main__":
    fetch_and_display_papers()
