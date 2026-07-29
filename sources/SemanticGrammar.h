//
//  SemanticGrammar.h
//  Squirrel
//

#ifndef SQUIRREL_SEMANTIC_GRAMMAR_H_
#define SQUIRREL_SEMANTIC_GRAMMAR_H_

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool SquirrelGrammarLoad(const char* model_path);
void SquirrelGrammarUnload(void);
double SquirrelGrammarScore(const char* context, const char* candidate);

#ifdef __cplusplus
}
#endif

#endif  // SQUIRREL_SEMANTIC_GRAMMAR_H_
