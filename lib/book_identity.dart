/// Local originals and virtual series share a reserved identity range.
const localBookIdStart = 0x60000000;
bool isLocalBook(int id) => id >= localBookIdStart;
