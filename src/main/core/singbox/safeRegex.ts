const MAX_PATTERN_LENGTH = 256

/** Compile Clash node filters while rejecting catastrophic backtracking constructs. */
export function compileSafeClashRegex(pattern: string): RegExp {
  let source = pattern
  let flags = ''
  if (source.startsWith('(?i)')) {
    source = source.slice(4)
    flags = 'i'
  }
  if (!source || source.length > MAX_PATTERN_LENGTH) {
    throw new Error(`filter regex must contain 1-${MAX_PATTERN_LENGTH} characters`)
  }
  if (/\\(?:[1-9]|k<)/.test(source)) {
    throw new Error('filter regex backreferences are not supported')
  }

  const groups: { containsQuantifier: boolean }[] = []
  let inCharacterClass = false
  let previousTokenWasQuantifier = false
  let closedGroupContainedQuantifier = false

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]
    if (character === '\\') {
      index += 1
      previousTokenWasQuantifier = false
      closedGroupContainedQuantifier = false
      continue
    }
    if (character === '[') {
      inCharacterClass = true
      previousTokenWasQuantifier = false
      closedGroupContainedQuantifier = false
      continue
    }
    if (character === ']' && inCharacterClass) {
      inCharacterClass = false
      previousTokenWasQuantifier = false
      closedGroupContainedQuantifier = false
      continue
    }
    if (inCharacterClass) continue

    if (character === '(') {
      if (source[index + 1] === '?' && source[index + 2] !== ':') {
        throw new Error('filter regex lookarounds and special groups are not supported')
      }
      if (source[index + 1] === '?' && source[index + 2] === ':') index += 2
      groups.push({ containsQuantifier: false })
      previousTokenWasQuantifier = false
      closedGroupContainedQuantifier = false
      continue
    }
    if (character === ')') {
      const group = groups.pop()
      if (!group) throw new Error('filter regex has unbalanced parentheses')
      closedGroupContainedQuantifier = group.containsQuantifier
      if (group.containsQuantifier && groups.length > 0) {
        groups[groups.length - 1].containsQuantifier = true
      }
      previousTokenWasQuantifier = false
      continue
    }

    let isQuantifier = character === '*' || character === '+' || character === '?'
    if (character === '{') {
      const match = source.slice(index).match(/^\{\d+(?:,\d*)?\}/)
      if (match) {
        isQuantifier = true
        index += match[0].length - 1
      }
    }
    if (isQuantifier) {
      if (previousTokenWasQuantifier || closedGroupContainedQuantifier) {
        throw new Error('filter regex contains nested or repeated quantifiers')
      }
      if (groups.length > 0) groups[groups.length - 1].containsQuantifier = true
      previousTokenWasQuantifier = true
      closedGroupContainedQuantifier = false
      continue
    }

    previousTokenWasQuantifier = false
    closedGroupContainedQuantifier = false
  }

  if (inCharacterClass || groups.length > 0) {
    throw new Error('filter regex has unbalanced delimiters')
  }
  return new RegExp(source, flags)
}
