import arxiv
import datetime
from datetime import timedelta
import pytz
import requests
import time
import re
import json
import feedparser
from dateutil import parser as date_parser
from bs4 import BeautifulSoup
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed


# --- Configuration ---
DAYS_BACK = 6
OLDEST_DATE_TO_INCLUDE = datetime.datetime.now(pytz.utc) - timedelta(days=DAYS_BACK)

ARXIV_CATEGORIES = ['physics.bio-ph', 'cond-mat.soft']
BIORXIV_COLLECTION = 'biophysics'

# --- Journal Feed Configuration ---
# Each feed has: url, name, group (include_all / section_filter / green_filter)
# include_all:     Fetch all papers from the feed
# section_filter:  Only include if tags/title/summary match the section_filter string
# green_filter:    Only include papers matching green author/keyword lists
JOURNAL_FEEDS = [
    # Group A: Include all papers from these biophysics-specific feeds
    {"url": "http://feeds.rsc.org/rss/sm", "name": "Soft Matter", "group": "include_all"},
    {"url": "https://www.cell.com/biophysj/inpress.rss", "name": "Biophysical Journal", "group": "include_all"},
    {"url": "https://feeds.aps.org/rss/tocsec/PRE-Biologicalphysics.xml", "name": "Physical Review E", "group": "include_all"},
    {"url": "https://feeds.aps.org/rss/tocsec/PRL-SoftMatterBiologicalandInterdisciplinaryPhysics.xml", "name": "PRL", "group": "include_all"},
    {"url": "https://feeds.aps.org/rss/recent/prx.xml", "name": "PRX", "group": "include_all"},
    {"url": "http://feeds.aps.org/rss/recent/prxlife.xml", "name": "PRX Life", "group": "include_all"},
    {"url": "https://feeds.aps.org/rss/recent/prresearch.xml", "name": "PRR", "group": "include_all"},
    {"url": "http://www.nature.com/subjects/biophysics.rss", "name": "Nature", "group": "include_all"},
    {"url": "https://www.pnas.org/action/showFeed?type=searchTopic&taxonomyCode=topic&tagCodeOr=biophys-bio&tagCodeOr=biophys-phys", "name": "PNAS", "group": "include_all"},
    # Group B: Broad feeds filtered by section
    {"url": "https://academic.oup.com/rss/site_6448/4114.xml", "name": "PNAS NEXUS", "group": "include_all"},
    {"url": "https://journals.plos.org/plosone/search/feed/atom?sortOrder=DATE_NEWEST_FIRST&filterJournals=PLoSONE&unformattedQuery=subject%3A%22biophysics%22", "name": "PLOS ONE", "group": "include_all"},
    {"url": "https://www.science.org/rss/express.xml", "name": "Science", "group": "section_filter", "section_filter": "Biophysics"},
    # Group C: Broad feeds filtered by green authors/keywords
    {"url": "https://www.cell.com/cell/current.rss", "name": "Cell", "group": "green_filter"},
    {"url": "https://elifesciences.org/rss/recent.xml", "name": "eLife", "group": "green_filter"},
    {"url": "https://www.molbiolcell.org/action/showFeed?type=etoc&feed=rss&jc=mboc", "name": "MBoC", "group": "green_filter"},
    # Development feed is 404
    # {"url": "https://journals.biologists.com/dev/rss/recent.xml", "name": "Development", "group": "green_filter"},
]

APS_SOURCES = ['PRL', 'PRX', 'PRX Life', 'Physical Review E', 'PRR']





def scrape_metadata(url):
    """Scrapes citation metadata from the article page."""
    try:
        # User-Agent is critical
        headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept-Encoding': 'gzip, deflate, br',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1',
            'Sec-Fetch-Dest': 'document',
            'Sec-Fetch-Mode': 'navigate',
            'Sec-Fetch-Site': 'none',
            'Sec-Fetch-User': '?1',
            'Cache-Control': 'max-age=0',
        }
        r = requests.get(url, headers=headers, timeout=10)
        if r.status_code != 200:
            # print(f"    - Scrape failed (Status {r.status_code}) for {url}")
            return None, None, None
            
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
                 
        # Extract Article Type for Filtering
        article_type = ""
        for meta in soup.find_all('meta', attrs={'name': ['citation_article_type', 'dc.Type', 'article:section']}):
            if meta.get('content'):
                article_type = meta['content'].strip()
                break
                  
        return authors, abstract, article_type
    except Exception as e:
        print(f"  Warning: Metadata scraping failed for {url}: {e}")
        return None, None, None


def clean_aps_abstract(summary):
    """Clean APS feed abstracts (PRL, PRX, PRX Life, PRE).
    
    APS RSS summaries look like:
      Author(s): ...<br /><p>Actual abstract text...</p><img src="..." /><br />[Journal ref]
    
    Returns: (clean_abstract, list_of_image_urls)
    """
    images = []
    if not summary:
        return "", images
    
    soup = BeautifulSoup(summary, 'html.parser')
    
    # Extract image URLs
    for img in soup.find_all('img'):
        src = img.get('src', '')
        if src:
            # Fix protocol-relative URLs
            if src.startswith('//'):
                src = 'https:' + src
            images.append(src)
        img.decompose()
    
    # Extract the actual abstract from <p> tags
    p_tags = soup.find_all('p')
    if p_tags:
        abstract = ' '.join(p.get_text(strip=True) for p in p_tags)
    else:
        abstract = soup.get_text(strip=True)
    
    # Remove "Author(s): ..." prefix (everything before the abstract)
    abstract = re.sub(r'^Author\(s\):.*?(?=\S{20,})', '', abstract, flags=re.DOTALL).strip()
    
    # Remove trailing journal citation like [Phys. Rev. Lett. 136, ...] Published ...
    abstract = re.sub(r'\[Phys\.\s*Rev\..*$', '', abstract).strip()
    abstract = re.sub(r'\[PRX\s+Life.*$', '', abstract).strip()
    
    return abstract, images


def clean_biorxiv_abstract(abstract):
    """Remove TOC graphics / figure markup from bioRxiv abstracts.
    
    Some bioRxiv abstracts have appended TOC graphics like:
      ... actual abstract.  TOC Graphic  O_FIG O_LINKSMALLFIG WIDTH=200...
      ... actual abstract.  Graphical Abstract  O_FIG ...
    
    Returns: clean abstract string
    """
    if not abstract:
        return abstract
    
    # Cut at common markers
    markers = ['TOC Graphic', 'Graphical Abstract', 'O_FIG O_LINKSMALLFIG', 'O_FIG\nO_LINKSMALLFIG']
    for marker in markers:
        idx = abstract.find(marker)
        if idx > 0:
            abstract = abstract[:idx].strip()
    
    return abstract


RSC_SOURCES = ['Soft Matter']

def clean_rsc_abstract(summary):
    """Clean RSC feed abstracts (Soft Matter, etc.).
    
    RSC RSS summaries contain multiple <div> blocks with:
      - Journal name, year, manuscript status, DOI
      - Open Access badge images
      - Creative Commons license images and links
      - Graphical abstract image (GA?id=...)
      - Author names + truncated abstract + RSC copyright footer
    
    Returns: (clean_abstract, authors_str, list_of_image_urls)
    """
    images = []
    if not summary:
        return "", "", images
    
    soup = BeautifulSoup(summary, 'html.parser')
    
    # Extract graphical abstract images (GA service URLs)
    for img in soup.find_all('img'):
        src = img.get('src', '')
        alt = img.get('alt', '')
        if src and 'ImageService/image/GA' in src:
            if src.startswith('//'):
                src = 'https:' + src
            elif src.startswith('http://'):
                src = src.replace('http://', 'https://', 1)
            images.append(src)
    
    # The content div is typically the last <div> containing author + abstract
    # It has pattern: AuthorNames<br/>Abstract text...<br/>The content of this RSS Feed...
    divs = soup.find_all('div')
    
    abstract = ""
    authors_str = ""
    
    for div in divs:
        text = div.get_text(separator='\n', strip=True)
        # Skip metadata divs (journal name, DOI, Open Access, Creative Commons)
        if text.startswith('Soft Matter') or text.startswith('Nanoscale'):
            continue
        if 'Open Access' in text and len(text) < 50:
            continue
        if 'Creative Commons' in text or 'licensed under' in text:
            continue
        
        # The content div has authors + abstract
        # Split on <br/> - first segment is authors, rest is abstract
        parts = []
        for child in div.children:
            if child.name == 'br':
                parts.append('\n')
            elif hasattr(child, 'get_text'):
                parts.append(child.get_text(strip=True))
            elif isinstance(child, str):
                t = child.strip()
                if t:
                    parts.append(t)
        
        full_text = ''.join(parts)
        segments = [s.strip() for s in full_text.split('\n') if s.strip()]
        
        # Need at least authors + abstract
        if len(segments) >= 2:
            # Filter out RSC copyright footer
            segments = [s for s in segments if 'The content of this RSS Feed' not in s
                       and 'To cite this article before page numbers' not in s]
            
            if segments:
                authors_str = segments[0]
                abstract = ' '.join(segments[1:])
    
    return abstract, authors_str, images


def fetch_crossref_metadata(doi):
    """Fetch author and abstract data from CrossRef API using a DOI.
    
    Returns: (authors_list, abstract_str) or (None, None) on failure.
    """
    if not doi:
        return None, None
    
    # Clean DOI - remove 'doi:' prefix if present
    doi = doi.replace('doi:', '').strip()
    
    try:
        r = requests.get(f'https://api.crossref.org/works/{doi}', timeout=10)
        if r.status_code != 200:
            return None, None
        
        data = r.json().get('message', {})
        
        # Extract authors
        authors = []
        for a in data.get('author', []):
            given = a.get('given', '')
            family = a.get('family', '')
            if given and family:
                authors.append(f"{given} {family}")
            elif family:
                authors.append(family)
        
        # Extract abstract (may have JATS XML tags)
        abstract = data.get('abstract', '')
        if abstract:
            # Strip JATS XML tags like <jats:p>, <jats:italic>, etc.
            abstract = re.sub(r'<[^>]+>', '', abstract).strip()
        
        return authors if authors else None, abstract if abstract else None
    except Exception as e:
        print(f"  Warning: CrossRef lookup failed for {doi}: {e}")
        return None, None



# Load whitelists
def load_list(filename):
    try:
        with open(filename, 'r') as f:
            return [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        print(f"Warning: {filename} not found.")
        return []

ORCID_PATTERN = re.compile(r'^(\d{4}-\d{4}-\d{4}-[\dX]{4})\s*-\s*(.+)$')

def load_green_authors_with_orcids(filename):
    """Parse greenauthors.txt. Lines can be:
       ORCID - Author Name   →  (orcid, name) tuple
       Author Name           →  (None, name) tuple
    Returns (orcid_list, name_list) where:
       orcid_list = [(orcid, name), ...] for CrossRef fetching
       name_list  = [name, ...] for green-filter matching on RSS papers
    """
    orcid_list = []
    name_list = []
    try:
        with open(filename, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                m = ORCID_PATTERN.match(line)
                if m:
                    orcid, name = m.group(1), m.group(2).strip()
                    orcid_list.append((orcid, name))
                    name_list.append(name)
                else:
                    name_list.append(line)
    except FileNotFoundError:
        print(f"Warning: {filename} not found.")
    return orcid_list, name_list

GREEN_ORCIDS, GREEN_AUTHORS = load_green_authors_with_orcids('greenauthors.txt')
GREEN_KEYWORDS = load_list('greenkeywords.txt')

def is_research_article(entry, source_name=None, authors_list=None, article_type=None):
    # Heuristic to filter out non-research content
    title = entry.get('title', '').strip()
    title_lower = title.lower()
    summary = entry.get('summary', '').lower()
    
    # Exclude common non-research terms in title
    exclude_terms = [
        'review', 'perspective', 'editorial', 'correction', 'comment', 'highlight', 
        'news', 'erratum', 'author correction', 'publisher correction', 
        'profile', 'q&a', 'inner workings', 'front matter', 'core concepts', 'opinion'
    ]
    if any(term in title_lower for term in exclude_terms):
        return False


    # Check explicitly scraped article type if available
    if article_type:
        type_lower = article_type.lower()
        if any(term in type_lower for term in ['commentary', 'perspective', 'editorial', 'news', 'interview', 'author summary', 'correction']):
            print(f"    - Filtered out non-research type: {article_type}")
            return False
        
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
    """Fetch papers from an RSS feed with optional section or green-author filtering."""
    print(f"Fetching {source_name}...")
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

            # Check Authors for Heuristic
            authors = []
            if 'authors' in entry:
                authors = [a.get('name', '') for a in entry.authors]
            elif 'author' in entry:
                 # PNAS might have "Firstname Lastname, Secondname Lastname" in author string
                 authors = [entry.author]

            # Initial "Research Article" Constraint (Title check only)
            if not is_research_article(entry, source_name=source_name, authors_list=authors):
                continue

            # Section filter: check tags, category, title, summary
            if group_type == 'section_filter' and section_filter:
                tags = [t.get('term', '').lower() for t in entry.get('tags', [])]
                tags += [t.get('label', '').lower() for t in entry.get('tags', [])]
                cat = entry.get('category', '').lower()
                sf = section_filter.lower()
                category_match = sf in tags or sf in cat
                text_match = sf in entry.get('title', '').lower() or sf in entry.get('summary', '').lower()
                if not (category_match or text_match):
                    continue

            # Green filter: only include papers matching green authors/keywords
            if group_type == 'green_filter':
                if not matches_green_filter(entry):
                    continue

            # Formatting
            authors = []
            if 'authors' in entry:
                authors = [a.get('name', '') for a in entry.authors]
            elif 'author' in entry:
                authors = [entry.author]
            
            abstract = entry.get('summary', '').replace('\n', ' ')
            images = []
            
            # --- APS Feed Cleaning (PRL, PRX, PRX Life, PRE, PRR) ---
            if source_name in APS_SOURCES:
                abstract, images = clean_aps_abstract(abstract)
            
            # --- RSC Feed Cleaning (Soft Matter, etc.) ---
            if source_name in RSC_SOURCES:
                rsc_abstract, rsc_authors, images = clean_rsc_abstract(entry.get('summary', ''))
                if rsc_abstract:
                    abstract = rsc_abstract
                if rsc_authors:
                    authors = [rsc_authors]
            
            # --- Data Quality Checks & Fallback ---
            needs_scrape = False
            
            # PNAS: Always scrape — RSS has smushed authors + truncated abstracts
            if source_name == "PNAS":
                needs_scrape = True
            
            # Check 1: Missing Authors (Nature, PNAS Nexus)
            elif not authors:
                needs_scrape = True
                
            # Check 2: Missing Abstract (Nature)
            if not abstract or len(abstract) < 20:
                needs_scrape = True
                
            if needs_scrape:
                print(f"    - Scraping metadata for: {entry.title[:30]}...")
                scraped_authors, scraped_abstract, scraped_type = scrape_metadata(entry.link)
                
                if scraped_authors:
                    authors = scraped_authors
                if scraped_abstract:
                    abstract = scraped_abstract
                
                # RE-CHECK FILTER WITH SCRAPED TYPE
                if scraped_type and not is_research_article(entry, article_type=scraped_type):
                    continue
                
                # CrossRef fallback for PNAS (scraping typically returns 403)
                if source_name == "PNAS" and (not scraped_authors or not scraped_abstract):
                    doi = entry.get('dc_identifier', '').replace('doi:', '').strip()
                    if not doi:
                        # Try extracting DOI from link
                        link = entry.get('link', '')
                        doi_match = re.search(r'10\.\d{4,}/[^\s?&#]+', link)
                        if doi_match:
                            doi = doi_match.group()
                    if doi:
                        print(f"    - CrossRef fallback for: {entry.title[:30]}...")
                        cr_authors, cr_abstract = fetch_crossref_metadata(doi)
                        if cr_authors and not scraped_authors:
                            authors = cr_authors
                        if cr_abstract and not scraped_abstract:
                            abstract = cr_abstract

            paper = {
                'source': source_name,
                'title': entry.title.replace('\n', ' '),
                'authors': ", ".join(authors),
                'link': entry.link,
                'abstract': abstract,
                'images': images,
                'date': published
            }
            papers.append(paper)
            
    except Exception as e:
        print(f"  Error fetching {source_name}: {e}")
        
    print(f"  Found {len(papers)} papers.")
    return papers

def fetch_arxiv_papers():
    print(f"Fetching arXiv papers...")
    query_string = " OR ".join([f"cat:{cat}" for cat in ARXIV_CATEGORIES])

    max_retries = 3
    for attempt in range(1, max_retries + 1):
        client = arxiv.Client()
        search = arxiv.Search(
            query=query_string,
            max_results=200, 
            sort_by=arxiv.SortCriterion.SubmittedDate,
            sort_order=arxiv.SortOrder.Descending
        )

        papers = []
        seen_ids = set()

        try:
            for result in client.results(search):
                published_date = result.published.replace(tzinfo=pytz.utc)
                
                if published_date < OLDEST_DATE_TO_INCLUDE:
                    break

                paper_id = result.entry_id.split('/')[-1].split('v')[0]
                
                if paper_id in seen_ids:
                    continue
                seen_ids.add(paper_id)

                if not is_research_article({'title': result.title, 'summary': result.summary}):
                     continue

                papers.append({
                    'source': 'arXiv',
                    'title': result.title.replace('\n', ' '),
                    'authors': ", ".join([author.name for author in result.authors]),
                    'link': result.entry_id,
                    'abstract': result.summary.replace('\n', ' '),
                    'images': [],
                    'date': published_date
                })
            print(f"  Found {len(papers)} arXiv papers.")
            return papers
        except Exception as e:
            wait_secs = 30 * attempt
            if attempt < max_retries:
                print(f"  arXiv error (attempt {attempt}/{max_retries}): {e}")
                print(f"  Waiting {wait_secs}s before retrying...")
                time.sleep(wait_secs)
            else:
                print(f"  arXiv error after {max_retries} attempts: {e}")
                print(f"  Continuing with {len(papers)} arXiv papers found so far.")
                return papers
    return []

def fetch_biorxiv_papers():
    print(f"Fetching bioRxiv papers...")
    start_date_str = OLDEST_DATE_TO_INCLUDE.strftime("%Y-%m-%d")
    end_date_str = datetime.datetime.now(pytz.utc).strftime("%Y-%m-%d")
    
    papers = []
    cursor = 0
    
    while True:
        url = f"https://api.biorxiv.org/details/biorxiv/{start_date_str}/{end_date_str}/{cursor}/json"
        
        # Retry logic for bioRxiv with rate-limit-aware backoff
        max_retries = 4
        data = None
        for attempt in range(1, max_retries + 1):
            try:
                response = requests.get(url, timeout=30)
                if response.status_code == 429:
                    wait_secs = 15 * attempt
                    print(f"  bioRxiv rate limit (429) at cursor {cursor}. Waiting {wait_secs}s (attempt {attempt}/{max_retries})...")
                    time.sleep(wait_secs)
                    continue
                response.raise_for_status()
                data = response.json()
                break 
            except requests.exceptions.HTTPError as e:
                wait_secs = 10 * attempt
                print(f"  bioRxiv HTTP error at cursor {cursor}: {e}. Waiting {wait_secs}s (attempt {attempt}/{max_retries})...")
                time.sleep(wait_secs)
            except Exception as e:
                wait_secs = 5 * attempt
                print(f"  bioRxiv error at cursor {cursor}: {e}. Waiting {wait_secs}s (attempt {attempt}/{max_retries})...")
                time.sleep(wait_secs)
        
        if not data or 'collection' not in data:
            break
        
        for item in data['collection']:
            if item.get('category') and item['category'].lower() == BIORXIV_COLLECTION.lower():
                try:
                    paper_date = datetime.datetime.strptime(item['date'], "%Y-%m-%d").replace(tzinfo=pytz.utc)
                except ValueError:
                    paper_date = datetime.datetime.now(pytz.utc)

                authors = item.get('authors', '')
                raw_abstract = item['abstract'].replace('\n', ' ')
                clean_abs = clean_biorxiv_abstract(raw_abstract)
                papers.append({
                    'source': 'bioRxiv',
                    'title': item['title'].replace('\n', ' '),
                    'authors': authors,
                    'link': f"https://www.biorxiv.org/content/{item['doi']}v{item['version']}",
                    'abstract': clean_abs,
                    'images': [],
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

CROSSREF_MAILTO = "lemma@princeton.edu"  # For polite pool (faster rate limits)

def _query_crossref_orcid(orcid, author_name, from_date):
    """Query CrossRef for a single author's recent papers by ORCID. Used by ThreadPoolExecutor."""
    results_papers = []
    max_retries = 4
    url = "https://api.crossref.org/works"
    params = {
        'filter': f'orcid:{orcid},from-pub-date:{from_date}',
        'rows': 10,
        'sort': 'published',
        'order': 'desc',
        'mailto': CROSSREF_MAILTO,
    }
    
    for attempt in range(1, max_retries + 1):
        try:
            r = requests.get(url, params=params, timeout=15)
            if r.status_code == 200:
                data = r.json()
                for item in data.get('message', {}).get('items', []):
                    title_parts = item.get('title', ['No Title'])
                    title = title_parts[0] if title_parts else 'No Title'
                    
                    # Parse authors
                    authors_raw = item.get('author', [])
                    authors_list = []
                    for a in authors_raw:
                        given = a.get('given', '')
                        family = a.get('family', '')
                        if given and family:
                            authors_list.append(f"{given} {family}")
                        elif family:
                            authors_list.append(family)
                    authors_str = ", ".join(authors_list) if authors_list else "Unknown"
                    
                    # DOI link
                    doi = item.get('DOI', '')
                    link = f"https://doi.org/{doi}" if doi else item.get('URL', '')
                    
                    # Abstract (CrossRef includes it for some publishers)
                    abstract_text = item.get('abstract', '')
                    if abstract_text:
                        # CrossRef abstracts sometimes have JATS XML tags
                        abstract_text = re.sub(r'<[^>]+>', '', abstract_text).strip()
                    if not abstract_text:
                        abstract_text = "Abstract not available via CrossRef API."
                    
                    # Publication date
                    date_parts = item.get('published', {}).get('date-parts', [[]])
                    if date_parts and date_parts[0]:
                        parts = date_parts[0]
                        year = parts[0] if len(parts) > 0 else 2026
                        month = parts[1] if len(parts) > 1 else 1
                        day = parts[2] if len(parts) > 2 else 1
                        pub_date = datetime.datetime(year, month, day, tzinfo=pytz.utc)
                    else:
                        pub_date = datetime.datetime.now(pytz.utc)
                    
                    results_papers.append({
                        'source': 'CrossRef/Featured',
                        'title': title.replace('\n', ' '),
                        'authors': authors_str,
                        'link': link,
                        'abstract': abstract_text,
                        'images': [],
                        'date': pub_date,
                        'doi': f"https://doi.org/{doi}" if doi else None
                    })
                return results_papers
            elif r.status_code == 429:
                wait_secs = 5 * attempt
                time.sleep(wait_secs)
                continue  # Retry
            else:
                # Non-retryable HTTP error
                print(f"  ❌ CrossRef failed for {author_name}: HTTP {r.status_code}")
                return results_papers
                
        except requests.exceptions.Timeout:
            if attempt < max_retries:
                time.sleep(3 * attempt)
            else:
                print(f"  ❌ CrossRef failed for {author_name}: timeout after {max_retries} attempts")
        except Exception as e:
            print(f"  ❌ CrossRef failed for {author_name}: {e}")
            return results_papers
        
    return results_papers


def fetch_crossref_papers():
    """Fetch recent papers by green-listed authors via CrossRef API using ORCIDs (parallelized)."""
    print(f"Fetching CrossRef papers for Green Authors ({len(GREEN_ORCIDS)} with ORCIDs)...")
    
    if not GREEN_ORCIDS:
        print("  No Green Authors with ORCIDs found to search.")
        return []
        
    papers = []
    from_date = OLDEST_DATE_TO_INCLUDE.strftime("%Y-%m-%d")
    
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(_query_crossref_orcid, orcid, name, from_date): name
            for orcid, name in GREEN_ORCIDS
        }
        for future in as_completed(futures):
            papers.extend(future.result())
            
    # Deduplicate internally — prefer DOI, fall back to title
    unique = {}
    for p in papers:
        key = p.get('doi') or p['title'].lower()
        if key not in unique:
            unique[key] = p
            
    print(f"  Found {len(unique)} unique papers from CrossRef.")
    return list(unique.values())

def fetch_and_display_papers():
    print(f"Fetching papers from {OLDEST_DATE_TO_INCLUDE.strftime('%Y-%m-%d')} to Now...")
    
    all_papers = []
    
    # 0. CrossRef (Featured) — parallelized internally
    all_papers.extend(fetch_crossref_papers())

    # 1. arXiv
    all_papers.extend(fetch_arxiv_papers())
    
    # 2. bioRxiv
    all_papers.extend(fetch_biorxiv_papers())
    
    # 3. Journal RSS feeds — fetched in parallel
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(
                fetch_rss,
                feed["url"],
                feed["name"],
                feed["group"],
                feed.get("section_filter")
            ): feed["name"]
            for feed in JOURNAL_FEEDS
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                all_papers.extend(future.result())
            except Exception as e:
                print(f"  Error fetching {name}: {e}")

    # --- Deduplication ---
    # Two-pass: first by DOI (exact match), then by normalized title
    unique_by_doi = {}
    no_doi_papers = []
    for p in all_papers:
        doi = p.get('doi')
        if doi:
            if doi not in unique_by_doi:
                unique_by_doi[doi] = p
            elif p['date'] < unique_by_doi[doi]['date']:
                unique_by_doi[doi] = p
        else:
            no_doi_papers.append(p)
    
    # Second pass: title-based dedup for papers without DOI + cross-check DOI papers
    unique_papers_map = {}
    for p in list(unique_by_doi.values()) + no_doi_papers:
        title_clean = "".join(e for e in p['title'].lower() if e.isalnum())
        if title_clean not in unique_papers_map:
            unique_papers_map[title_clean] = p
        elif p['date'] < unique_papers_map[title_clean]['date']:
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
        if paper.get('images'):
            output_lines.append("")
            output_lines.append("**Key Images:**")
            for img_url in paper['images']:
                output_lines.append(f"- ![key image]({img_url})")
        output_lines.append(f"</details>")
        output_lines.append("") 
        output_lines.append("---")
        output_lines.append("")

    # Write structured data to JSON for the AI filter script
    with open("papers.json", "w") as f:
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
