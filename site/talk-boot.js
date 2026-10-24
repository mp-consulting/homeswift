// Runs before the first paint (not deferred): turns the entrance and the scroll reveals on, so the hero never
// flashes in its final state first. Without scripts the page shows as it is, with no motion.
document.documentElement.classList.add('motion');
