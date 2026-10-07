/// A badge's number: past 99 it stops counting, since the tally does too.
String countLabel(int count) => count > 99 ? '99+' : '$count';
