async (page) => {
  await page.evaluate(() => { document.body.style.zoom = '2'; });
  await page.waitForTimeout(300);
  const dir = 'output/playwright/agent-panel';
  for (const id of ['c1', 'c2', 'c3']) {
    await page.locator(`#${id}`).screenshot({ path: `${dir}/${id}.png` });
  }
  return 'ok';
}
