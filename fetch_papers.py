import arxiv
import datetime
from datetime import timedelta
import pytz
import requests
import time
import feedparser
from dateutil import parser as date_parser
from bs4 import BeautifulSoup

def scrape_metadata(url):
    """Scrapes citation metadata from the article page."""
    try:
        # User-Agent is critical
        headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://www.google.com/',
            'Upgrade-Insecure-Requests': '1',
            'Sec-Fetch-Dest': 'document',
            'Sec-Fetch-Mode': 'navigate',
            'Sec-Fetch-Site': 'cross-site',
        }
        r = requests.get(url, headers=headers, timeout=10)
        if r.status_code != 200:
            # print(f"    - Scrape failed (Status {r.status_code}) for {url}")
            return None, None
            
        soup = BeautifulSoup(r.content, 'html.parser')
        
        # Extract Authors
        authors = []
        # Standard citation_author metatags
        for meta in soup.find_all('meta', attrs={'name': 'citation_author'}):
            if meta.get('content'):
                authors.append(meta['content'])
        if not authors:
             # Try DC.creator
             for meta in soup.find_all('meta', attrs={'name': 'DC.creator'}):
                if meta.get('content'):
                    authors.append(meta['content'].strip())
                    
        # Extract Abstract
        abstract = ""
        # citation_abstract
        meta_abs = soup.find('meta', attrs={'name': 'citation_abstract'})
        if meta_abs and meta_abs.get('content'):
             abstract = meta_abs['content'].strip()
        else:
             # DC.description
             meta_desc = soup.find('meta', attrs={'name': 'DC.description'})
             if meta_desc and meta_desc.get('content'):
                 abstract = meta_desc['content'].strip()
             else:
                 # og:description (Nature uses this often)
                 meta_og = soup.find('meta', attrs={'property': 'og:description'})
                 if meta_og and meta_og.get('content'):
                     abstract = meta_og['content'].strip()
                 
        return authors, abstract
    except Exception as e:
        print(f"  Warning: Metadata scraping failed for {url}: {e}")
        return None, None

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
            
            abstract = entry.get('summary', '').replace('\n', ' ')
            
            # --- Data Quality Checks & Fallback ---
            needs_scrape = False
            
            # Check 1: Missing Authors (Nature, PNAS Nexus)
            if not authors:
                needs_scrape = True
                
            # Check 2: PNAS "Mashed" Authors (Long string, no commas)
            elif source_name == "PNAS" and len(authors) == 1 and "," not in authors[0] and len(authors[0]) > 20:
                needs_scrape = True
                
            # Check 3: Missing Abstract (Nature)
            if not abstract or len(abstract) < 20:
                needs_scrape = True

            # Check 4: Soft Matter / RSC Feeds (Abstract is HTML soup)
            # The feed returns <div><i><b>Soft Matter</b></i>... instead of abstract
            if source_name == "Soft Matter" or abstract.strip().startswith("<div"):
                needs_scrape = True
                
            if needs_scrape:
                print(f"    - Scraping metadata for: {entry.title[:30]}...")
                scraped_authors, scraped_abstract = scrape_metadata(entry.link)
                
                if scraped_authors:
                    authors = scraped_authors
                if scraped_abstract:
                    abstract = scraped_abstract

            paper = {
                'source': source_name,
                'title': entry.title.replace('\n', ' '),
                'authors': ", ".join(authors),
                'link': entry.link,
                'abstract': abstract,
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

def fetch_openalex_papers():
    print(f"Fetching OpenAlex papers for Green Authors...")
    # Just to be safe, reload green authors here or pass it in
    # Use global GREEN_AUTHORS list loaded at top
    
    if not GREEN_AUTHORS:
        print("  No Green Authors found to search.")
        return []
        
    papers = []
    
    # Calculate date range
    from_date = OLDEST_DATE_TO_INCLUDE.strftime("%Y-%m-%d")
    
    # OpenAlex filter format: from_publication_date:2023-10-01
    
    # We will search for each author. 
    # Note: Search by distinct name can be noisy if common name, but Green Authors list is usually specific.
    # OpenAlex 'works' endpoint.
    
    base_works_url = "https://api.openalex.org/works"
    
    # To be polite and avoid rate limits, we'll do sequential requests.
    for author_name in GREEN_AUTHORS:
        # Step 1: Find Author ID
        try:
            # Search for author
            auth_r = requests.get("https://api.openalex.org/authors", params={'search': author_name}, timeout=10)
            if auth_r.status_code != 200:
                print(f"  Failed to search author '{author_name}': {auth_r.status_code}")
                continue
                
            auth_data = auth_r.json()
            if not auth_data.get('results'):
                print(f"  No author found for '{author_name}'")
                continue
                
            # Take top result
            author_id = auth_data['results'][0]['id'] # formatted as https://openalex.org/A...
            # OpenAlex API expects just the ID part or the full URI usually works. 
            # Let's extract just the ID part A... if needed, but the filter author.id accepts the full URI too.
            
            # Step 2: Fetch Works
            params = {
                'filter': f'author.id:{author_id},from_publication_date:{from_date}',
                'per-page': 10,
                'sort': 'publication_date:desc'
            }
            
            r = requests.get(base_works_url, params=params, timeout=10)
            if r.status_code == 200:
                data = r.json()
                results = data.get('results', [])
                if results:
                    # print(f"  Found {len(results)} matches for '{author_name}'")
                    for work in results:
                        # Extract fields
                        title = work.get('title', 'No Title')
                        
                        # Authors string
                        try:
                            authors_list = [a['author']['display_name'] for a in work.get('authorships', [])]
                            authors_str = ", ".join(authors_list)
                        except:
                            authors_str = "Unknown"
                            
                        # Link and DOI
                        # OpenAlex provides 'doi' field and 'id' (openalex id)
                        link = work.get('doi')
                        if not link:
                            link = work.get('id') # Fallback to OA ID if no DOI
                            
                        # Abstract
                        # OpenAlex uses an inverted index for abstract. We need to reconstruct it?
                        # Wait, the documentation says 'abstract_inverted_index'.
                        # Reconstructing is complex.
                        # Sometimes 'best_oa_location' has a pdf_url or landing_page_url.
                        # We might need to stick to the 'abstract' if available?
                        # Actually, OpenAlex *only* provides inverted index for abstracts in the free tier response usually.
                        # Reconstructing:
                        inverted = work.get('abstract_inverted_index')
                        abstract_text = ""
                        if inverted:
                            # Reconstruct
                            # Create a list of (index, word)
                            word_index = []
                            for word, indices in inverted.items():
                                for idx in indices:
                                    word_index.append((idx, word))
                            word_index.sort()
                            abstract_text = " ".join([w[1] for w in word_index])
                        
                        if not abstract_text:
                            # Fallback?
                            abstract_text = "Abstract not available via OpenAlex API."

                        # Date
                        pub_date_str = work.get('publication_date')
                        if pub_date_str:
                            pub_date = datetime.datetime.strptime(pub_date_str, "%Y-%m-%d").replace(tzinfo=pytz.utc)
                        else:
                            pub_date = datetime.datetime.now(pytz.utc)

                        # Filter for "Research Article"?
                        # work['type'] might be 'article', 'preprint', etc.
                        # We'll allow preprints too.
                        
                        papers.append({
                            'source': 'OpenAlex/Featured',
                            'title': title.replace('\n', ' '),
                            'authors': authors_str,
                            'link': link,
                            'abstract': abstract_text,
                            'date': pub_date,
                            'doi': work.get('doi') # Store DOI for dedup
                        })
            elif r.status_code == 429:
                print("  Rate limit hit for OpenAlex. Sleeping...")
                time.sleep(2)
            else:
                pass
                # print(f"  Failed query for {author_name}: {r.status_code}")
                
            time.sleep(0.2) # Polite delay
            
        except Exception as e:
            print(f"  Error querying OpenAlex for {author_name}: {e}")
            
    # Deduplicate internally within OpenAlex results first
    unique_oa = {}
    for p in papers:
        # Use DOI or Title
        key = p.get('doi') or p['title'].lower()
        if key not in unique_oa:
            unique_oa[key] = p
            
    print(f"  Found {len(unique_oa)} unique papers from OpenAlex.")
    return list(unique_oa.values())

def fetch_and_display_papers():
    print(f"Fetching papers from {OLDEST_DATE_TO_INCLUDE.strftime('%Y-%m-%d')} to Now...")
    
    all_papers = []
    
    # 0. OpenAlex (Featured)
    all_papers.extend(fetch_openalex_papers())

    # 1. Group A: General (arXiv)
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
 
    # PLOS ONE (biophysics)
    all_papers.extend(fetch_rss("https://journals.plos.org/plosone/search/feed/atom?sortOrder=DATE_NEWEST_FIRST&filterJournals=PLoSONE&unformattedQuery=subject%3A%22biophysics%22", "PLOS ONE", "B"))
    
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

    # Write structured data to JSON for the AI filter script
    import json
    with open("papers.json", "w") as f:
        # Convert datetime objects to string for JSON serialization
        json_ready_list = []
        for p in final_list:
            p_copy = p.copy()
            p_copy['date'] = p['date'].isoformat()
            json_ready_list.append(p_copy)
        json.dump(json_ready_list, f, indent=4)
    print(f"Saved structured data to papers.json")

    # Write to file (Raw)
    with open("raw_papers.md", "w") as f:
        f.write(f"# Weekly Paper Update (RAW)\n")
        f.write(f"**Date Range:** {OLDEST_DATE_TO_INCLUDE.strftime('%Y-%m-%d')} to {datetime.datetime.now().strftime('%Y-%m-%d')}\n")
        f.write(f"**Total Papers Found:** {total_count}\n")
        
        # Add Source Breakdown
        from collections import Counter
        source_counts = Counter([p['source'] for p in final_list])
        breakdown = ", ".join([f"{src}: {count}" for src, count in source_counts.most_common()])
        f.write(f"**Sources:** {breakdown}\n\n")
        
        if not output_lines:
            f.write("No papers found in this date range.\n")
        else:
            f.write("\n".join(output_lines))
    
    print(f"\nDone. Found {total_count} total unique papers.")
    print("Saved to raw_papers.md")

if __name__ == "__main__":
    fetch_and_display_papers()
