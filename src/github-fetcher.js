// src/github-fetcher.js
export class GitHubFetcher {
  constructor(env) {
    this.env = env;
    this.token = env.GITHUB_TOKEN;
    this.owner = env.GITHUB_REPO_OWNER || 'sugan0927';
    this.repo = env.GITHUB_REPO_NAME || 'easyinstallvps';
    this.branch = env.GITHUB_BRANCH || 'main';
    this.cache = new Map();
    this.cacheTimeout = 5 * 60 * 1000; // 5 minutes
  }

  async fetchFile(filePath, useCache = true) {
    const cacheKey = `${filePath}-${this.branch}`;
    
    // Check cache
    if (useCache && this.cache.has(cacheKey)) {
      const cached = this.cache.get(cacheKey);
      if (Date.now() - cached.timestamp < this.cacheTimeout) {
        console.log(`Cache hit for ${filePath}`);
        return cached.data;
      }
    }

    try {
      const url = `https://api.github.com/repos/${this.owner}/${this.repo}/contents/${filePath}?ref=${this.branch}`;
      
      const response = await fetch(url, {
        headers: {
          'Authorization': `token ${this.token}`,
          'Accept': 'application/vnd.github.v3.raw',
          'User-Agent': 'Cloudflare-Worker',
          'X-GitHub-Api-Version': '2022-11-28'
        }
      });

      if (!response.ok) {
        if (response.status === 404) {
          throw new Error(`File not found: ${filePath}`);
        }
        if (response.status === 403) {
          const resetTime = response.headers.get('X-RateLimit-Reset');
          throw new Error(`GitHub API rate limit exceeded. Resets at ${new Date(resetTime * 1000).toLocaleString()}`);
        }
        throw new Error(`GitHub API error: ${response.status} ${response.statusText}`);
      }

      const content = await response.text();

      // Save to cache
      if (useCache) {
        this.cache.set(cacheKey, {
          data: content,
          timestamp: Date.now()
        });
      }

      return content;

    } catch (error) {
      console.error('GitHub fetch error:', error);
      throw error;
    }
  }

  async fetchMultipleFiles(filePaths) {
    const promises = filePaths.map(path => this.fetchFile(path, true));
    const results = await Promise.allSettled(promises);
    
    return filePaths.reduce((acc, path, index) => {
      const result = results[index];
      acc[path] = result.status === 'fulfilled' ? result.value : null;
      return acc;
    }, {});
  }

  async getFileList(path = '') {
    const url = `https://api.github.com/repos/${this.owner}/${this.repo}/contents/${path}?ref=${this.branch}`;
    
    const response = await fetch(url, {
      headers: {
        'Authorization': `token ${this.token}`,
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'Cloudflare-Worker'
      }
    });

    if (!response.ok) {
      throw new Error(`Failed to fetch file list: ${response.status}`);
    }

    return await response.json();
  }

  clearCache() {
    this.cache.clear();
    console.log('Cache cleared');
  }
}
