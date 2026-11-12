// Pages with nothing of their own to run (the 404): the shared chrome, and
// the path that wasn't found, in the terminal that says so.

import { startPage } from './ui.js';

startPage();

const path = document.getElementById('lost-path');
if (path) path.textContent = location.pathname;
