/**
 * JenesisNow Policy Scraper
 * Uses Puppeteer to log into JenesisNow, find a policy by number, and scrape all data.
 */
const puppeteer = require('puppeteer');

const JENESIS_BASE = 'https://ww12.jenesisnow.net';
let browserInstance = null;
let browserLastUsed = 0;
const BROWSER_TTL = 5 * 60 * 1000; // close browser after 5 min idle

async function getBrowser() {
    if (browserInstance && browserInstance.connected) {
        browserLastUsed = Date.now();
        return browserInstance;
    }
    browserInstance = await puppeteer.launch({
        headless: 'new',
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
        executablePath: '/usr/bin/google-chrome',
    });
    browserLastUsed = Date.now();
    // Auto-close after idle
    const check = setInterval(() => {
        if (Date.now() - browserLastUsed > BROWSER_TTL && browserInstance) {
            browserInstance.close().catch(() => {});
            browserInstance = null;
            clearInterval(check);
        }
    }, 30000);
    return browserInstance;
}

async function loginToJenesis(page) {
    // Use cookie-based login via the same POST method as jenesis-routes.js (faster, more reliable)
    const axios = require('axios');
    const params = new URLSearchParams();
    params.append('email', process.env.JENESIS_EMAIL);
    params.append('password', process.env.JENESIS_PASSWORD);
    const resp = await axios.post(JENESIS_BASE + '/login/login', params.toString(), {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        maxRedirects: 5,
    });
    const raw = resp.headers['set-cookie'];
    if (!raw || !raw.length) throw new Error('JenesisNow login failed — no cookies returned');
    // Set cookies on the browser page
    const cookies = raw.map(c => {
        const parts = c.split(';')[0].split('=');
        return { name: parts[0], value: parts.slice(1).join('='), domain: 'ww12.jenesisnow.net', path: '/' };
    });
    await page.setCookie(...cookies);
    console.log(`[JenesisNow Scraper] Login successful, set ${cookies.length} cookies`);
}

async function findPolicyByNumber(page, policyNumber, clientName) {
    // Go to client list and search
    await page.goto(JENESIS_BASE + '/client', { waitUntil: 'networkidle2', timeout: 30000 });

    // JenesisNow client DataTable searches by client name, not policy number.
    // clientName may contain multiple names separated by ||
    const searchTerms = [];
    const allNames = (clientName || '').split('||').map(s => s.trim()).filter(Boolean);
    // Deduplicate
    const seen = new Set();
    for (const name of allNames) {
        if (seen.has(name.toLowerCase())) continue;
        seen.add(name.toLowerCase());
        // Try cleaned version first (strip LLC etc.)
        const cleaned = name.replace(/\b(LLC|L\.L\.C|Inc|Corp|Ltd|Co|Trucking|Transport|Logistics|Enterprises|Services|Global)\b/gi, '').trim();
        if (cleaned && !seen.has(cleaned.toLowerCase())) {
            seen.add(cleaned.toLowerCase());
            searchTerms.push(cleaned);
        }
        searchTerms.push(name);
    }
    searchTerms.push(policyNumber);
    console.log(`[JenesisNow Scraper] Search terms: ${searchTerms.join(' | ')}`);

    // Debug: log current URL and page state
    const currentUrl = page.url();
    console.log(`[JenesisNow Scraper] After login, URL is: ${currentUrl}`);
    const pageTitle = await page.title();
    console.log(`[JenesisNow Scraper] Page title: ${pageTitle}`);
    // Check if DataTable exists
    const dtExists = await page.evaluate(() => {
        return {
            jQueryExists: typeof jQuery !== 'undefined',
            tableExists: !!document.querySelector('#clientDatatable'),
            bodyText: document.body?.textContent?.substring(0, 200) || ''
        };
    });
    console.log(`[JenesisNow Scraper] jQuery: ${dtExists.jQueryExists}, Table: ${dtExists.tableExists}`);
    if (!dtExists.tableExists) {
        console.log(`[JenesisNow Scraper] Page body: ${dtExists.bodyText}`);
    }

    let clientFound = false;
    for (const term of searchTerms) {
        console.log(`[JenesisNow Scraper] Trying search: "${term}"`);
        clientFound = await page.evaluate((searchTerm) => {
            return new Promise((resolve) => {
                try {
                    const table = jQuery('#clientDatatable').DataTable();
                    table.search(searchTerm).draw();
                    setTimeout(() => {
                        const row = document.querySelector('#clientDatatable tbody tr');
                        const text = row ? row.textContent.trim().substring(0, 100) : '';
                        if (row && !text.includes('No matching') && !text.includes('No data') && text.length > 5) {
                            row.click();
                            resolve(true);
                        } else {
                            resolve(false);
                        }
                    }, 3000);
                } catch (e) { resolve(false); }
            });
        }, term);
        if (clientFound) {
            console.log(`[JenesisNow Scraper] Found client with search: "${term}"`);
            break;
        }
    }

    if (!clientFound) return null;
    // Wait for client page to load after row click
    await Promise.race([
        page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 15000 }).catch(() => {}),
        page.waitForFunction(() => window.location.href.includes('/client/view/'), { timeout: 15000 }).catch(() => {}),
    ]);
    await new Promise(r => setTimeout(r, 2000)); // let page render

    // Now on client view page — find the policy row and click it
    const policyClicked = await page.evaluate((polNum) => {
        return new Promise((resolve) => {
            setTimeout(() => {
                const rows = document.querySelectorAll('tr[class*="policy"]');
                for (const row of rows) {
                    if (row.textContent.includes(polNum)) {
                        row.click();
                        return resolve(true);
                    }
                }
                // Fallback: any table row with the policy number
                document.querySelectorAll('table tr').forEach(r => {
                    if (r.textContent.includes(polNum) && !r.textContent.includes('Policy Type')) {
                        r.click();
                        resolve(true);
                    }
                });
                resolve(false);
            }, 2000);
        });
    }, policyNumber);

    if (!policyClicked) return null;
    // Wait for policy page to load after row click
    await Promise.race([
        page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 15000 }).catch(() => {}),
        page.waitForFunction(() => window.location.href.includes('/viewpolicy/'), { timeout: 15000 }).catch(() => {}),
    ]);
    await new Promise(r => setTimeout(r, 2000)); // let page render
    return page.url(); // e.g. /client/viewpolicy/1234567
}

async function scrapePolicy(page) {
    return await page.evaluate(() => {
        return new Promise((resolve) => {
            setTimeout(() => {
                const result = { fields: {}, coverages: [], vehicles: [], drivers: [], notes: [] };

                // URL and title
                result.url = window.location.href;
                result.title = document.title;
                const idMatch = window.location.href.match(/viewpolicy\/(\d+)/);
                result.jenesisId = idMatch ? idMatch[1] : '';

                // All form fields
                document.querySelectorAll('input, select, textarea').forEach(el => {
                    const label = el.closest('.form-group, .input-group, div')?.querySelector('label')?.textContent?.trim() || '';
                    const name = el.name || el.id || '';
                    const val = el.tagName === 'SELECT' ? (el.options[el.selectedIndex]?.text || el.value) : el.value;
                    if ((label || name) && val && val !== '0' && !label.includes('Search') && !label.includes('Show') && !label.includes('Display')) {
                        const key = label || name;
                        if (!result.fields[key]) result.fields[key] = val;
                    }
                });

                // Coverages
                document.querySelectorAll('table').forEach(t => {
                    const h = t.textContent.substring(0, 120);
                    if (h.includes('Coverage') && h.includes('Limit') && h.includes('Deductible')) {
                        t.querySelectorAll('tbody tr').forEach(r => {
                            const cells = Array.from(r.querySelectorAll('td'));
                            const code = cells[1]?.textContent?.trim() || '';
                            if (!code) return;
                            const limitSel = cells[2]?.querySelector('select');
                            const limitInp = cells[2]?.querySelector('input');
                            const limit = limitSel ? (limitSel.options[limitSel.selectedIndex]?.text || '') : (limitInp?.value || cells[2]?.textContent?.trim() || '');
                            const dedSel = cells[3]?.querySelector('select');
                            const dedInp = cells[3]?.querySelector('input');
                            const deductible = dedSel ? (dedSel.options[dedSel.selectedIndex]?.text || '') : (dedInp?.value || cells[3]?.textContent?.trim() || '');
                            const premInp = cells[4]?.querySelector('input');
                            const premium = premInp?.value || cells[4]?.textContent?.trim() || '';
                            result.coverages.push({ code, limit: limit.replace(/\n/g, '').trim(), deductible: deductible.replace(/\n/g, '').trim(), premium });
                        });
                    }
                });

                // Vehicles
                document.querySelectorAll('table').forEach(t => {
                    const h = t.textContent.substring(0, 80);
                    if (h.includes('Vehicle') && h.includes('VIN')) {
                        t.querySelectorAll('tbody tr').forEach(r => {
                            const cells = Array.from(r.querySelectorAll('td')).map(c => c.textContent.trim());
                            if (cells.length >= 2 && cells[0]) {
                                const m = cells[0].match(/^(\d{4})\s+(.+?)(?:\s+(\S+))?$/);
                                result.vehicles.push({
                                    description: cells[0],
                                    year: m ? m[1] : '',
                                    makeModel: m ? m[2] : cells[0],
                                    vin: cells[1] || '',
                                    addDel: cells[2] || '',
                                    effective: cells[3] || '',
                                });
                            }
                        });
                    }
                });

                // Drivers — just collect row count and data-itemid for now
                // (detail extraction happens in a separate step by clicking each row)
                document.querySelectorAll('table').forEach(t => {
                    const h = t.textContent.substring(0, 100);
                    if (h.includes('Name') && h.includes('Add/Del') && h.includes('Effective')) {
                        t.querySelectorAll('tbody tr').forEach(r => {
                            const cells = Array.from(r.querySelectorAll('td')).map(c => c.textContent.trim());
                            const itemId = r.getAttribute('data-itemid') || '';
                            if (cells.length >= 1 && cells[0]) {
                                result.drivers.push({ name: cells[0], addDel: cells[1] || '', effective: cells[2] || '', _itemId: itemId });
                            }
                        });
                    }
                });

                // Notes - find notes by content pattern
                document.querySelectorAll('table tbody tr').forEach(r => {
                    const text = r.textContent.trim();
                    if ((text.includes('Downloaded:') || text.includes('Corp:') || text.includes('Support:') || text.includes('Endorsement')) && text.match(/\d{2}-\d{2}-\d{4}/)) {
                        const cells = Array.from(r.querySelectorAll('td')).map(c => c.textContent.trim());
                        if (cells.length >= 2) {
                            result.notes.push({ text: cells[0], date: cells[1] || '' });
                        }
                    }
                });

                // Also try getting more notes by showing all
                const notesTables = document.querySelectorAll('table');
                for (const t of notesTables) {
                    if (t.id && t.id.toLowerCase().includes('note')) {
                        t.querySelectorAll('tbody tr').forEach(r => {
                            const cells = Array.from(r.querySelectorAll('td')).map(c => c.textContent.trim());
                            if (cells.length >= 2 && cells.join(' ').length > 10) {
                                const exists = result.notes.some(n => n.text === cells[0] && n.date === cells[1]);
                                if (!exists) result.notes.push({ text: cells[0], date: cells[1] || '' });
                            }
                        });
                    }
                }

                resolve(result);
            }, 2000);
        });
    });
}

async function scrapePolicyByNumber(policyNumber, clientName) {
    const browser = await getBrowser();
    const page = await browser.newPage();
    page.setDefaultTimeout(30000);

    try {
        await loginToJenesis(page);
        const url = await findPolicyByNumber(page, policyNumber, clientName);
        if (!url) {
            await page.close();
            return { error: 'Policy not found in JenesisNow' };
        }
        const data = await scrapePolicy(page);

        // Step 2: Click each driver row to open modal and extract DOB, license, etc.
        if (data.drivers && data.drivers.length > 0) {
            for (let i = 0; i < data.drivers.length; i++) {
                const drv = data.drivers[i];
                try {
                    // Click the driver row to open the detail modal
                    const clicked = await page.evaluate((idx) => {
                        const rows = document.querySelectorAll('#commercialAutoDriverDatatable tbody tr, .drivers table tbody tr');
                        if (rows[idx]) { rows[idx].click(); return true; }
                        return false;
                    }, i);

                    if (!clicked) continue;
                    // Wait for modal to appear
                    await new Promise(r => setTimeout(r, 1500));

                    // Extract driver details from the modal
                    const details = await page.evaluate(() => {
                        const g = (id) => {
                            const el = document.getElementById(id);
                            if (!el) return '';
                            if (el.tagName === 'SELECT') return el.options[el.selectedIndex]?.text || el.value || '';
                            return el.value || '';
                        };
                        return {
                            firstName: g('Firstname'),
                            middleName: g('Middlename'),
                            lastName: g('Lastname'),
                            dateOfBirth: g('Dateofbirth'),
                            licenseNumber: g('Licensenumber'),
                            licenseState: g('State'),
                            gender: g('Gender'),
                            maritalStatus: g('Maritalstatus'),
                            relationship: g('Relationship'),
                            stateLicYear: g('Statelicenseyear'),
                            origLicDate: g('Originallicensedate'),
                            yearsCommExp: g('Yearscommercialexperience'),
                            ssn: '', // don't scrape SSN
                        };
                    });

                    // Merge into driver record
                    if (details.firstName || details.lastName) {
                        drv.firstName = details.firstName;
                        drv.middleName = details.middleName;
                        drv.lastName = details.lastName;
                    }
                    if (details.dateOfBirth) drv.dateOfBirth = details.dateOfBirth;
                    if (details.licenseNumber) drv.licenseNumber = details.licenseNumber;
                    if (details.licenseState) drv.licenseState = details.licenseState;
                    if (details.gender) drv.gender = details.gender;
                    if (details.stateLicYear) drv.stateLicYear = details.stateLicYear;

                    // Close modal
                    await page.evaluate(() => {
                        const cancelBtn = document.querySelector('#ModalCancelButton, .ModalCancelButton');
                        if (cancelBtn) cancelBtn.click();
                    });
                    await new Promise(r => setTimeout(r, 500));
                } catch (e) {
                    console.warn(`[JenesisNow Scraper] Failed to get driver ${i} details:`, e.message);
                }
            }
        }

        // Step 3: Click each vehicle row to open modal and extract details + per-vehicle coverages
        if (data.vehicles && data.vehicles.length > 0) {
            for (let i = 0; i < data.vehicles.length; i++) {
                const veh = data.vehicles[i];
                try {
                    const clicked = await page.evaluate((idx) => {
                        const rows = document.querySelectorAll('#commercialAutoVehicleDatatable tbody tr, .vehicles table tbody tr');
                        if (rows[idx]) { rows[idx].click(); return true; }
                        return false;
                    }, i);

                    if (!clicked) continue;
                    await new Promise(r => setTimeout(r, 1500));

                    const details = await page.evaluate(() => {
                        const g = (id) => {
                            const el = document.getElementById(id);
                            if (!el) return '';
                            if (el.tagName === 'SELECT') {
                                const opt = el.options[el.selectedIndex];
                                return opt ? (opt.text || opt.value || '') : '';
                            }
                            return el.value || '';
                        };
                        const result = {
                            vin: g('Vin'),
                            year: g('Year'),
                            make: g('Make'),
                            model: g('Model'),
                            bodyType: g('Bodytype'),
                            territory: g('Territory'),
                            gvw: g('Gvwgcw'),
                            vehicleClass: g('Class'),
                            garageAddress: g('Garageaddress'),
                            garageCity: g('Garagecity'),
                            garageState: g('Garagestate'),
                            garageZip: g('Garagezip'),
                            garageCounty: g('Garagecounty'),
                            dotNumber: g('DotNum'),
                            mcNumber: g('McNum'),
                            costNew: g('Costnew'),
                            use: g('Use'),
                            radius: g('Radius'),
                            cargoLimit: g('Cargolimit'),
                        };
                        // Per-vehicle coverages from the modal's coverage table
                        result.coverages = [];
                        document.querySelectorAll('#commercialAutoPolicyVehicleCoveragesDatatable tbody tr').forEach(r => {
                            const codeEl = r.querySelector('.coverageCode');
                            const code = codeEl ? codeEl.textContent.trim() : '';
                            if (!code) return;
                            const limitInp = r.querySelector('input[data-id^="cov_"]');
                            const dedInp = r.querySelector('input[data-id^="ded_"]') || r.querySelector('select[id*="_Deductible_"]');
                            const premInp = r.querySelector('input[data-id^="prem_"]');
                            const descInp = r.querySelector('input[id*="_Description_"]');
                            const limit = limitInp ? limitInp.value : '';
                            let deductible = '';
                            if (dedInp) {
                                deductible = dedInp.tagName === 'SELECT'
                                    ? (dedInp.options[dedInp.selectedIndex]?.text || '')
                                    : dedInp.value;
                            }
                            const premium = premInp ? premInp.value : '';
                            const description = descInp ? descInp.value : '';
                            result.coverages.push({ code, limit, deductible, premium, description });
                        });
                        return result;
                    });

                    // Merge vehicle details
                    if (details.vin) veh.vin = details.vin;
                    if (details.year) veh.year = details.year;
                    if (details.make) veh.make = details.make;
                    if (details.model) veh.model = details.model;
                    if (details.bodyType) veh.bodyType = details.bodyType;
                    if (details.gvw) veh.gvw = details.gvw;
                    if (details.garageState) veh.garageState = details.garageState;
                    if (details.garageZip) veh.garageZip = details.garageZip;
                    if (details.garageAddress) veh.garageAddress = details.garageAddress;
                    if (details.garageCity) veh.garageCity = details.garageCity;
                    if (details.dotNumber) veh.dotNumber = details.dotNumber;
                    if (details.mcNumber) veh.mcNumber = details.mcNumber;
                    if (details.use) veh.use = details.use;
                    if (details.radius) veh.radius = details.radius;
                    if (details.costNew) veh.costNew = details.costNew;
                    if (details.coverages && details.coverages.length) veh.coverages = details.coverages;

                    // Close modal
                    await page.evaluate(() => {
                        const cancelBtn = document.querySelector('#ModalCancelButton, .ModalCancelButton');
                        if (cancelBtn) cancelBtn.click();
                    });
                    await new Promise(r => setTimeout(r, 500));
                } catch (e) {
                    console.warn(`[JenesisNow Scraper] Failed to get vehicle ${i} details:`, e.message);
                }
            }
        }

        await page.close();
        return data;
    } catch (err) {
        await page.close().catch(() => {});
        return { error: err.message };
    }
}

module.exports = { scrapePolicyByNumber };
