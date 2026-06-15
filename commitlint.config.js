module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // type-enum is intentionally not overridden here: @commitlint/config-conventional
    // already supplies the full conventional-commits type list. Duplicating it here
    // only creates drift risk on upstream upgrades.
    'subject-case': [2, 'never', ['pascal-case', 'upper-case']],
    'body-max-line-length': [1, 'always', 100],
    'footer-max-line-length': [1, 'always', 100],
  },
};
